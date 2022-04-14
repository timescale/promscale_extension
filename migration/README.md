# SQL Migration scripts

## General structure

TODO james

## Security

As this extension is marked as trusted, it is imperative that we follow the
Postgres guidelines on Security Considerations for Extensions [1]. In general,
there are two classes of vulnerability which we need to account for:

a) Unsafe object creation 
b) Unsafe search_path

In the next couple of paragraphs we will (briefly) explain the mechanisms
behind these vulnerabilities. This description is not intended to be fully
comprehensive.

Unsafe object creation is an attack which can be applied when the extension
uses `CREATE OR REPLACE` or `CREATE ... IF NOT EXISTS`. In this attack, the
attacker pre-creates an object which will later be `CREATE OR REPLACE`d by the
extension during installation. As the attacker is the owner of this object,
they can later modify the object and get malicious code executed.

Unsafe search_path is an attack which can be applied when the extension does
not sufficiently schema-qualify objects. In this attack, the  attacker creates
an object (in a schema which they own), and tricks the extension into
using (or executing) that object instead of the intended object. This is
possible because objects with better-matching signatures are chosen over
objects which take more general arguments.

Note: The fact that the Promscale extension is marked as trusted means that all
SQL in the install script, and all `SECURITY DEFINER` functions are executed as
the bootstrap superuser.

The Promscale extension's approach to securing its SQL consists of the following:

1. `CREATE` all schemas which will contain objects (without `IF NOT EXISTS`)
2. Use `CREATE OR REPLACE` or `CREATE ... IF NOT EXISTS` in those schemas
3. Use `SET search_path = pg_catalog` on functions and procedures where possible
4. Explicitly schema-qualify all objects and operators in functions without `SET search_path = pg_catalog`
5. Use `SET LOCAL search_path = pg_catalog;` on procedures which perform transaction control
6. Explicitly `REVOKE ALL ... FROM PUBLIC` for `SECURITY DEFINER` functions and procedures

Step 1. ensures that the bootstrap superuser (on Postgres 13 and 14) or the
installing superuser (on postgres 12) is the owner of all schemas. If a schema
already exists before the extension is created, then the creation will fail.
This is by design. If schemas were allowed to be owned by another user, then
that user could hijack ownership of `SECURITY DEFINER` functions and escalate
privileges to the boostrap superuser.

Step 1. allows step 2. to be safe. With it, we know that only superusers can
own the extension's schemas, meaning that it is safe to use `CREATE OR REPLACE`
or `CREATE ... IF NOT EXISTS`, as only a superuser could pre-create an object
in the extension's schema, and superusers already have superuser privileges.

Step 3. ensures that the bodies of our `SQL` and `PLPGSQL` functions are not
vulnerable to the _Unsafe search_path_ attack.
Note: There are situations in which we cannot or do not want to use
`SET search_path`, for instance in procedures performing transaction control,
or for functions which we desire to be inlined.

Step 4. must be applied in situations in which Step 3. cannot be applied.

Step 5. provides additional security in procedures which perform transaction
control. Note: This approach is not possible in functions, and not necessary
for procedures which do not perform transaction control, which is why we do
not use it for them.

Step 6. is necessary, as by default functions are executable by `PUBLIC`, which
is undesirable for `SECURITY DEFINER`.

[1]: https://www.postgresql.org/docs/current/extend-extensions.html#EXTEND-EXTENSIONS-SECURITY