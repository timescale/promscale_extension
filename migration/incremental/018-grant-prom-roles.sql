-- Grant roles to the session user (the one that is installing the extension)
GRANT prom_reader TO SESSION_USER WITH ADMIN OPTION;
GRANT prom_writer TO SESSION_USER WITH ADMIN OPTION;
GRANT prom_maintenance TO SESSION_USER WITH ADMIN OPTION;
GRANT prom_modifier TO SESSION_USER WITH ADMIN OPTION;
GRANT prom_admin TO SESSION_USER WITH ADMIN OPTION;
