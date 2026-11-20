"""Загружает CSV в PostgreSQL и собирает файлы проекта."""

import argparse
import csv
from pathlib import Path
import shutil
import subprocess
from tempfile import TemporaryDirectory


PROJECT = Path(__file__).resolve().parents[1]
HEADER = ["InvoiceNo", "StockCode", "Description", "Quantity",
          "InvoiceDate", "UnitPrice", "CustomerID", "Country"]
EXPORTS = ["cleaning", "monthly_sales", "retention", "second_purchase",
           "customer_segments", "product_priority", "product_documents", "order_mix",
           "basket_pairs", "checks"]
SQL_FILES = ["01_source.sql", "02_cleaning.sql", "03_analysis.sql", "03_growth_and_baskets.sql",
             "04_quality.sql", "06_export.sql"]


def build(source, psql, database):
    with source.open(encoding="utf-8-sig", newline="") as csv_file:
        if next(csv.reader(csv_file), []) != HEADER:
            raise SystemExit("Проверь заголовок CSV. Нужен официальный файл Online Retail от UCI.")

    with TemporaryDirectory(prefix="retail-build-", dir=PROJECT) as temporary:
        stage = Path(temporary)
        shutil.copyfile(source, stage / "source.csv")

        sql = [r"\encoding UTF8", "SET client_min_messages TO warning;", "SET DateStyle TO 'ISO, MDY';"]
        for file_name in SQL_FILES:
            sql.append((PROJECT / "sql" / file_name).read_text(encoding="utf-8"))
            if file_name == "01_source.sql":
                sql.append(r"\copy raw_lines (invoice_no, stock_code, description, quantity, invoice_date, unit_price, customer_id, country) FROM 'source.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')")

        (stage / "build.sql").write_text("\n".join(sql) + "\n", encoding="utf-8")
        command = [psql, "-X", "-qAt", "-v", "ON_ERROR_STOP=1",
                   "--single-transaction", "-d", database, "-f", "build.sql"]
        if subprocess.run(command, cwd=stage).returncode != 0:
            raise SystemExit("Сборка PostgreSQL завершилась с ошибкой.")

        dashboard = PROJECT / "dashboard"
        snapshot = (stage / "dashboard-data.json").read_text(encoding="utf-8").strip()
        template = (dashboard / "index.template.html").read_text(encoding="utf-8")
        page = template.replace("__RETAIL_DATA__", snapshot.replace("<", r"\u003c"))
        (stage / "index.html").write_text(page, encoding="utf-8")

        results = PROJECT / "results"
        results.mkdir(exist_ok=True)
        for name in EXPORTS:
            (stage / f"{name}.csv").replace(results / f"{name}.csv")
        (stage / "dashboard-data.json").replace(results / "dashboard-data.json")
        (stage / "index.html").replace(dashboard / "index.html")

    print("Схема retail_repeat собрана.")
    print("Проверки и выгрузки сохранены в", results)
    print("Дашборд сохранён в", dashboard / "index.html")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", help="Путь к CSV Online Retail")
    parser.add_argument("--dbname", default="retail_repeat", help="Имя базы PostgreSQL")
    parser.add_argument("--psql", default="psql", help="Путь к psql, если его нет в PATH")
    args = parser.parse_args()

    source_path = args.source
    if source_path is None:
        source_path = input("Путь к CSV (Enter для retail-data/online_retail.csv): ").strip()
    source = Path(source_path.strip('"')) if source_path else PROJECT / "retail-data" / "online_retail.csv"

    client = shutil.which(args.psql)
    if client is None:
        raise SystemExit("psql не найден. Укажи полный путь через --psql.")
    if not source.is_file():
        raise SystemExit(f"CSV не найден: {source}")
    build(source, str(Path(client).resolve()), args.dbname)
