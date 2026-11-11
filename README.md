# FORGED Men's Ministry App

The members-only app for FORGED at **https://app.menofforged.com** (public site: https://menofforged.com).

- `index.html` is the app.
- `config.js` holds the Supabase project address and its public (publishable) key. It is safe to publish, because every table is locked down with row-level security.
- `supabase/setup.sql` is the database setup (tables, security rules, storage). It has already been run.
- Hosted free on GitHub Pages. Changes pushed to `main` go live in about a minute.
