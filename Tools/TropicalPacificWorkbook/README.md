# Tropical Pacific Workbook Inspector

This repository-local tool reads the Tropical Pacific source workbook with
`openpyxl` and writes a concise structural and key-integrity profile.

```sh
python3 Tools/TropicalPacificWorkbook/inspect_workbook.py
python3 Tools/TropicalPacificWorkbook/inspect_workbook.py path/to/workbook.xlsx
```

The inspector opens workbooks read-only/data-only and never saves or modifies
them. It does not produce app-ready species records or bulk JSON. Future passes
will perform record transformation separately.
