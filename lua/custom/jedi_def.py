"""The definition of the Python name at a position, as jedi resolves it.

    python jedi_def.py PATH LINE COLUMN [ENVIRONMENT] < SOURCE

LINE is 1-based and COLUMN a 0-based character offset, jedi's convention.
SOURCE is the buffer text, so an unsaved edit counts. ENVIRONMENT is the
Python whose site-packages jedi should read -- a virtualenv or an interpreter
-- since the one running this script is uvx's throwaway env with only jedi in
it; one jedi cannot load falls back to that default.

Prints one rg --vimgrep line (path:line:column:text, 1-based byte column) per
definition, so custom.locations.from_vimgrep reads the output as-is. Prints
nothing when jedi cannot resolve the name -- an import it cannot follow, a
module that is not installed -- or when the definition has no source file.
"""

import sys

import jedi


def environment(spec):
    """None means jedi's default: the env running this script."""
    if spec:
        try:
            return jedi.create_environment(spec, safe=False)
        except jedi.InvalidPythonEnvironment:
            pass
    return None


def vimgrep(name):
    line = name.get_line_code().rstrip('\r\n')
    column = len(line[: name.column].encode()) + 1
    return f'{name.module_path}:{name.line}:{column}:{line.strip()}'


def main():
    path, line, column = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    spec = sys.argv[4] if len(sys.argv) > 4 else None
    script = jedi.Script(
        sys.stdin.read(),
        path=path,
        project=jedi.get_default_project(path),
        environment=environment(spec),
    )
    for name in script.goto(line, column, follow_imports=True):
        if name.module_path is not None and name.line is not None:
            print(vimgrep(name))


if __name__ == '__main__':
    main()
