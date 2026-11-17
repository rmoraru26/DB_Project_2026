# Database checks

The database team's first checks of the schema and the sample data. They are the eight tests of
`database/database_tests.sql` (run after `schema.sql` and `seed.sql`; every change is rolled back).
`tests/database/run_database_tests.sh` now runs that file and checks its annotations automatically
(each expected error must occur with its code and constraint, and no other): 10 checks, run by
`make test-db` and as part of `make test`. Latest recorded run: 10 passed, 0 failed
(`docs/evidence/cycle3/linux-13.0.2/20-make-test.txt`).

| Test | Result |
|---|---|
| Schema and sample data loaded | Passed |
| Booking linked to the correct user and room | Passed |
| Zero room capacity rejected | Passed |
| Booking ending before its start rejected | Passed |
| Duplicate email rejected | Passed |
| Booking for a nonexistent user rejected | Passed |
| Loan linked to the correct user and item | Passed |
| Returned loan without a return date rejected | Passed |
