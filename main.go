package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"flag"
	"log/slog"
	"os"
	"strings"
	"text/template"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

//go:embed query.sql
var embeddedQuery string

type SectionRule struct {
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Prefixes    []string `json:"prefixes"`
	Contains    []string `json:"contains"`
	Exact       []string `json:"exact"`
}

type SchemaConfig struct {
	Name     string        `json:"name"`
	Sections []SectionRule `json:"sections"`
}

type Config struct {
	ConnectionString        string         `json:"connection_string"`
	TemplateFile            string         `json:"template_file"`
	Header                  string         `json:"header"`
	Footer                  string         `json:"footer"`
	DefaultSection          string         `json:"default_section"`
	DefaultSectionDesc      string         `json:"default_section_description"`
	IncludeTriggerFunctions bool           `json:"include_trigger_functions"`
	IncludeEnums            bool           `json:"include_enums"`
	IncludeDomains          bool           `json:"include_domains"`
	IncludeConstraints      bool           `json:"include_constraints"`
	IncludeIndexes          bool           `json:"include_indexes"`
	Schemas                 []SchemaConfig `json:"schemas"`
}

type DbObject struct {
	SchemaName     string `json:"schema_name"`
	ObjectType     string `json:"object_type"`
	ObjectName     string `json:"object_name"`
	ArgumentsSql   string `json:"arguments_sql"`
	ResultTypeSql  string `json:"result_type_sql"`
	ColumnsSql     string `json:"columns_sql"`
	IndexesSql     string `json:"indexes_sql"`
	TriggersSql    string `json:"triggers_sql"`
	ConstraintsSql string `json:"constraints_sql"`
	PoliciesSql    string `json:"policies_sql"`
	Comment        string `json:"comment"`
}

type SectionData struct {
	Name        string
	Description string
	Items       []DbObject
}

type SchemaData struct {
	Name          string
	Comment       string
	Sections      []SectionData
	SchemaComment string
}

type TemplateData struct {
	Header      string
	Footer      string
	Schemas     []SchemaData
	GeneratedAt string
}

func loadConfig(path string) (*Config, error) {
	configFile, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg Config
	if err := json.Unmarshal(configFile, &cfg); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func fetchMetadata(ctx context.Context, conn *pgx.Conn, schemaNames []string, cfg *Config) ([]DbObject, error) {
	rows, err := conn.Query(ctx, embeddedQuery, schemaNames, cfg.IncludeTriggerFunctions, cfg.IncludeEnums, cfg.IncludeDomains, cfg.IncludeIndexes, cfg.IncludeConstraints)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var objects []DbObject
	for rows.Next() {
		var obj DbObject
		if err := rows.Scan(
			&obj.SchemaName,
			&obj.ObjectType,
			&obj.ObjectName,
			&obj.ArgumentsSql,
			&obj.ResultTypeSql,
			&obj.ColumnsSql,
			&obj.IndexesSql,
			&obj.TriggersSql,
			&obj.ConstraintsSql,
			&obj.PoliciesSql,
			&obj.Comment,
		); err != nil {
			return nil, err
		}

		objects = append(objects, obj)
	}
	return objects, nil
}

func buildTemplateData(cfg *Config, objects []DbObject) TemplateData {
	defaultSec := cfg.DefaultSection
	if defaultSec == "" {
		defaultSec = "Другое"
	}

	var templateSchemas []SchemaData

	for _, schemaCfg := range cfg.Schemas {
		var schemaObjects []DbObject
		var schemaComment string

		for _, obj := range objects {
			if obj.SchemaName == schemaCfg.Name {
				if obj.ObjectType == "schema" {
					schemaComment = obj.Comment
				} else {
					schemaObjects = append(schemaObjects, obj)
				}
			}
		}

		var schemaSections []SectionData
		assigned := make(map[string]bool)

		if len(schemaCfg.Sections) > 0 {
			for _, rule := range schemaCfg.Sections {
				var matchedItems []DbObject
				for _, obj := range schemaObjects {
					if assigned[obj.ObjectName] {
						continue
					}

					matched := false
					for _, ex := range rule.Exact {
						if obj.ObjectName == ex {
							matched = true
							break
						}
					}
					if !matched {
						for _, pref := range rule.Prefixes {
							if strings.HasPrefix(obj.ObjectName, pref) {
								matched = true
								break
							}
						}
					}
					if !matched {
						for _, cont := range rule.Contains {
							if strings.Contains(obj.ObjectName, cont) {
								matched = true
								break
							}
						}
					}

					if matched {
						matchedItems = append(matchedItems, obj)
						assigned[obj.ObjectName] = true
					}
				}

				if len(matchedItems) > 0 {
					schemaSections = append(schemaSections, SectionData{
						Name:        rule.Name,
						Description: rule.Description,
						Items:       matchedItems,
					})
				}
			}

			var leftovers []DbObject
			for _, obj := range schemaObjects {
				if !assigned[obj.ObjectName] {
					leftovers = append(leftovers, obj)
				}
			}
			if len(leftovers) > 0 {
				schemaSections = append(schemaSections, SectionData{
					Name:        defaultSec,
					Description: cfg.DefaultSectionDesc,
					Items:       leftovers,
				})
			}
		} else {
			// Если разделы для схемы не заданы в конфиге, выводим все объекты единым блоком без заголовка раздела
			if len(schemaObjects) > 0 {
				schemaSections = append(schemaSections, SectionData{
					Name:        "",
					Description: "",
					Items:       schemaObjects,
				})
			}
		}

		if len(schemaObjects) > 0 || schemaComment != "" {
			templateSchemas = append(templateSchemas, SchemaData{
				Name:          schemaCfg.Name,
				SchemaComment: schemaComment,
				Sections:      schemaSections,
			})
		}
	}

	return TemplateData{
		Header:  cfg.Header,
		Footer:  cfg.Footer,
		Schemas: templateSchemas,
	}
}

func renderMarkdown(outputFile string, cfg *Config, data TemplateData) error {
	tmplContent, err := os.ReadFile(cfg.TemplateFile)
	if err != nil {
		return err
	}

	t, err := template.New("readme").Parse(string(tmplContent))
	if err != nil {
		return err
	}

	if outputFile == "" {
		outputFile = "API.md"
	}

	file, err := os.Create(outputFile)
	if err != nil {
		return err
	}
	defer file.Close()

	return t.Execute(file, data)
}

func main() {
	configPath := flag.String("config", "config.json", "путь к файлу конфигурации")
	outputFile := flag.String("output", "API.md", "путь к результирующему файлу документации")
	dumpFile := flag.String("dump", "", "путь для сохранения разобранных метаданных в формате JSON")
	flag.Parse()

	if _, err := os.Stat(*configPath); os.IsNotExist(err) {
		slog.Error("файл конфигурации не найден", slog.String("path", *configPath))
		os.Exit(1)
	}

	slog.Info("загрузка конфигурации", slog.String("path", *configPath))

	cfg, err := loadConfig(*configPath)
	if err != nil {
		slog.Error("ошибка конфигурации", "err", err)
		os.Exit(1)
	}

	connStr := cfg.ConnectionString
	if connStr == "" {
		slog.Error("строка подключения к базе данных не указана в конфигурации")
		os.Exit(1)
	}

	ctx := context.Background()

	conn, err := pgx.Connect(ctx, connStr)
	if err != nil {
		slog.Error("ошибка подключения к бд", "err", err)
		os.Exit(1)
	}
	defer conn.Close(ctx)

	var schemaNames []string
	for _, s := range cfg.Schemas {
		schemaNames = append(schemaNames, s.Name)
	}

	objects, err := fetchMetadata(ctx, conn, schemaNames, cfg)
	if err != nil {
		slog.Error("ошибка получения метаданных", "err", err)
		LogPgError(err)
		os.Exit(1)
	}

	if *dumpFile != "" {
		jsonData, err := json.MarshalIndent(objects, "", "    ")
		if err != nil {
			slog.Error("ошибка сериализации метаданных в JSON", "err", err)
			os.Exit(1)
		}
		if err := os.WriteFile(*dumpFile, jsonData, 0o644); err != nil {
			slog.Error("ошибка записи файла дампа", "err", err)
			os.Exit(1)
		}
		slog.Info("дамп метаданных успешно сохранен", slog.String("file", *dumpFile))
	}

	data := buildTemplateData(cfg, objects)
	data.GeneratedAt = time.Now().Format("02.01.2006 15:04:05")

	if err := renderMarkdown(*outputFile, cfg, data); err != nil {
		slog.Error("ошибка рендеринга документации", "err", err)
		os.Exit(1)
	}

	slog.Info("документация успешно сгенерирована", "file", *outputFile)
}

// LogPgError детально разбирает и логирует ошибку PostgreSQL
func LogPgError(err error) {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		slog.Error(
			"ошибка получения метаданных",
			slog.String("severity", pgErr.Severity),
			slog.String("code", pgErr.Code), // SQLSTATE
			slog.String("message", pgErr.Message),
			slog.String("detail", pgErr.Detail),
			slog.String("hint", pgErr.Hint),
			slog.Int("position", int(pgErr.Position)),
			slog.Int("internal_position", int(pgErr.InternalPosition)),
			slog.String("internal_query", pgErr.InternalQuery),
			slog.String("where", pgErr.Where),
			slog.String("schema", pgErr.SchemaName),
			slog.String("table", pgErr.TableName),
			slog.String("column", pgErr.ColumnName),
			slog.String("data_type", pgErr.DataTypeName),
			slog.String("constraint", pgErr.ConstraintName),
			slog.String("file", pgErr.File),
			slog.Int("line", int(pgErr.Line)),
			slog.String("routine", pgErr.Routine),
		)
	} else {
		slog.Error("ошибка получения метаданных", slog.Any("err", err))
	}
}
