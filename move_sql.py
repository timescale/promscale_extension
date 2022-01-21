#!/usr/bin/env python3
from pathlib import Path
import shutil
from typing import List, Dict, Tuple, Any

input_path = Path('/Users/james/Development/promscale/pkg/migrations/sql')
output_path = Path('/Users/james/Development/promscale_extension/migration')


def preinstall() -> List[Dict[str, Any]]:
    files = []
    for p in input_path.joinpath('preinstall').glob('**/*.sql'):
        if p.is_file() and p.exists():
            num, dash, rest = p.name.partition('-')
            if dash == '-':
                num = int(num)
                files.append({
                    'from_num': num,
                    'from_name': rest,
                    'from_path': p,
                    'is_idempotent': False,
                })
    files.sort(key=lambda x: x['from_num'])
    return files


def idempotent() -> List[Dict[str, Any]]:
    names = [
        'base.sql',
        'tag-operators.sql',
        'matcher-functions.sql',
        'ha.sql',
        'metric-metadata.sql',
        'exemplar.sql',
        'tracing-tags.sql',
        'tracing-functions.sql',
        'tracing-views.sql',
        'telemetry.sql',
        'maintenance.sql',
        'remote-commands.sql',
        'apply_permissions.sql',
    ]
    base = input_path.joinpath('idempotent')
    files = []
    num = 0
    for name in names:
        num = num + 1
        p = base.joinpath(name)
        files.append({
            'from_num': num,
            'from_name': name,
            'from_path': p,
            'is_idempotent': True,
        })
    return files


def process_list(files: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    i = 0
    for file in files:
        i = i + 1
        name = str(file['from_name']).lower().replace('_', '-')
        suffix = "idempotent" if file['is_idempotent'] else "migration"
        p = output_path.joinpath(suffix).joinpath(f"{str(i).rjust(3, '0')}-{name}")
        file['to_num'] = i
        file['to_name'] = name
        file['to_path'] = p
    return files


def move(files: List[Dict[str, Any]]) -> None:
    for file in files:
        shutil.copyfile(file['from_path'], file['to_path'])


def rewrite(files: List[Dict[str, Any]]) -> None:
    substitutions = [
        ("SELECT setval('_ps_trace.tag_key_id_seq', 1000);", "PERFORM setval('_ps_trace.tag_key_id_seq', 1000);"),
    ]
    for file in files:
        p = file['to_path']
        code = p.read_text()
        for f, r in substitutions:
            code = code.replace(f, r)
        p.write_text(code)


def prep_dirs() -> None:
    shutil.rmtree(output_path, ignore_errors=True)
    output_path.mkdir(parents=True)
    output_path.joinpath("migration").mkdir()
    output_path.joinpath("idempotent").mkdir()


if __name__ == '__main__':
    files_list = [preinstall(), idempotent()]
    prep_dirs()
    for files in files_list:
        processed_files = process_list(files)
        move(processed_files)
        rewrite(processed_files)
