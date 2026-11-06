"""Validated release inputs shared by project generation and packaging."""
import re


def validate(version, build_number, commit):
    if (not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version)
            or not re.fullmatch(r'[1-9][0-9]*', str(build_number))
            or not re.fullmatch(r'[0-9a-f]{40}', commit)):
        raise ValueError('invalid release metadata: expected numeric X.Y.Z, positive build number, and full lowercase commit SHA')
    return {'version': version, 'build_number': int(build_number), 'commit': commit}
