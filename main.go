package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"flag"
	"log/slog"
	"os"
	"strings"
	"text/template"
	"time"

	"github.com/jackc/pgx/v5"
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
	OutputFile              string         `json:"output_file"`
	TemplateFile            string         `json:"template_file"`
	Header                  string         `json:"header"`
	Footer                  string         `json:"footer"`
	DefaultSection          string         `json:"default_section"`
	DefaultSectionDesc      string         `json:"default_section_description"`
	IncludeTriggerFunctions bool           `json:"include_trigger_functions"`
	Schemas                 []SchemaConfig `json:"schemas"`
}

type DbObject struct {
	SchemaName    string `json:"schema_name"`
	ObjectType    string `json:"object_type"`
	ObjectName    string `json:"object_name"`
	ArgumentsSql  string `json:"arguments_sql"`
	ResultTypeSql string `json:"result_type_sql"`
	ColumnsSql    string `json:"columns_sql"`
	IndexesSql    string `json:"indexes_sql"`
	TriggersSql   string `json:"triggers_sql"`
	Comment       string `json:"comment"`
}

type SectionData struct {
	Name        string
	Description string
	Items       []DbObject
}

type SchemaData struct {
	Name     string
	Sections []SectionData
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

func fetchMetadata(ctx context.Context, conn *pgx.Conn, schemaNames []string, includeTriggers bool) ([]DbObject, error) {
	rows, err := conn.Query(ctx, embeddedQuery, schemaNames, includeTriggers)
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
			&obj.Comment,
		); err != nil {
			return nil, err
		}

		if obj.ArgumentsSql != "" {
			parts := strings.Split(obj.ArgumentsSql, ", ")
			for i, p := range parts {
				parts[i] = "    " + strings.TrimSpace(p)
			}
			obj.ArgumentsSql = strings.Join(parts, ",\n")
		}

		if obj.ColumnsSql != "" {
			obj.ColumnsSql = "    " + obj.ColumnsSql
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
		for _, obj := range objects {
			if obj.SchemaName == schemaCfg.Name {
				schemaObjects = append(schemaObjects, obj)
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

		if len(schemaSections) > 0 {
			templateSchemas = append(templateSchemas, SchemaData{
				Name:     schemaCfg.Name,
				Sections: schemaSections,
			})
		}
	}

	return TemplateData{
		Header:  cfg.Header,
		Footer:  cfg.Footer,
		Schemas: templateSchemas,
	}
}

func renderMarkdown(cfg *Config, data TemplateData) error {
	tmplContent, err := os.ReadFile(cfg.TemplateFile)
	if err != nil {
		return err
	}

	t, err := template.New("readme").Parse(string(tmplContent))
	if err != nil {
		return err
	}

	outFile := cfg.OutputFile
	if outFile == "" {
		outFile = "API.md"
	}

	file, err := os.Create(outFile)
	if err != nil {
		return err
	}
	defer file.Close()

	return t.Execute(file, data)
}

func main() {
	configPath := flag.String("config", "config.json", "путь к файлу конфигурации")
	flag.Parse()

	if _, err := os.Stat(*configPath); os.IsNotExist(err) {
		slog.Error("файл конфигурации не найден", slog.String("path", *configPath))
		os.Exit(1)
	}

	slog.Info("загрузка конфигурации", slog.String("path", *configPath))

	cfg, err := loadConfig("config.json")
	if err != nil {
		slog.Error("ошибка конфигурации", "err", err)
		os.Exit(1)
	}

	connStr := cfg.ConnectionString
	if connStr == "" {
		connStr = "postgres://localhost:5432/freeswitch?sslmode=disable&test=true"
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

	objects, err := fetchMetadata(ctx, conn, schemaNames, cfg.IncludeTriggerFunctions)
	if err != nil {
		slog.Error("ошибка получения метаданных", "err", err)
		os.Exit(1)
	}

	data := buildTemplateData(cfg, objects)
	data.GeneratedAt = time.Now().Format("02.01.2006 15:04:05")

	if err := renderMarkdown(cfg, data); err != nil {
		slog.Error("ошибка рендеринга документации", "err", err)
		os.Exit(1)
	}

	slog.Info("документация успешно сгенерирована", "file", cfg.OutputFile)
}
