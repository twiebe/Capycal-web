# capycal.app

The website of [Capycal](https://github.com/twiebe/capycal): plain HTML and CSS, no build step. The Pages workflow (`.github/workflows/pages.yml`) publishes it together with the Capycal book from `twiebe/capycal`, built with mdBook into `/docs`.

- `index.html`, `imprint.html`, `404.html` and `assets/` are the site; `CNAME` sets the domain
- Inter (`assets/fonts`, SIL Open Font License) is served from the site itself, nothing loads from other servers
- The screenshots in `assets/shots` come from the macOS app in light mode
- The book rebuilds on every push here, on `workflow_dispatch` and when the docs workflow of `twiebe/capycal` sends a `docs` dispatch
- `/packages` holds the APT and RPM repositories, rebuilt on every run from the newest three releases of `twiebe/capycal` (`scripts/fetch-releases.sh`, `scripts/build-repos.sh`) and signed with the secret `PACKAGES_GPG_KEY`; without it the site goes out without them. The debs are copied into the site, the RPM metadata points at the release downloads. Its release workflow sends a `release` dispatch once a release is out

To test the repositories: `make test-repos` (only Docker) builds them with a throwaway key and installs from them in Debian, Ubuntu and Fedora containers.

To preview: `make preview` (python3 and curl) or `make preview-docker` (only Docker), then open http://localhost:8000. Both build the book from the Capycal repo next to this one (`CAPYCAL=../capycal`, set it if yours is elsewhere) into `_site/docs`, fetching mdBook if it is not installed.
