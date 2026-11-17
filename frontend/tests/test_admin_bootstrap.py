from werkzeug.security import check_password_hash

import bootstrap_admin


def test_generated_credential_is_unique_and_hash_matches():
    first = bootstrap_admin.generate_credential()
    second = bootstrap_admin.generate_credential()
    assert first[0] == second[0] == "admin@frantastic.local"
    assert first[1] != second[1]
    assert len(first[1]) >= 32
    assert check_password_hash(first[2], first[1])
    assert not check_password_hash(first[2], second[1])


def test_command_outputs_machine_readable_credential(capsys):
    assert bootstrap_admin.main([]) == 0
    lines = capsys.readouterr().out.splitlines()
    assert len(lines) == 3
    assert lines[0] == "admin@frantastic.local"
    assert check_password_hash(lines[2], lines[1])
