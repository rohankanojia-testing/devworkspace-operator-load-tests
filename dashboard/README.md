# Load test dashboard

A static page for the three kinds of load test: controller, webhook and backup. You
pick the kind at the top; each metric then gets one chart, with its value on the y
axis and the releases, oldest to newest, on the x axis. It shows the last 5 releases
by default.

It is published to GitHub Pages by `.github/workflows/publish-dashboard.yml` on every
push to `main` that touches `dashboard/`.

## One-time setup

In the repository settings, open **Pages** and set **Source** to **GitHub Actions**.

## Adding a release

Each release is a folder under `dashboard/results/` holding up to three CSVs, one per
kind of test. A release does not need all three.

```
dashboard/results/1.1.0/
  controller_load_test_results.csv
  webhook_load_test_results.csv
  backup_load_test_results.csv
```

The helper script copies a CSV in under the right name. The last argument is the kind
of test and defaults to `controller`.

```sh
dashboard/scripts/add-result.sh 1.1.0 outputs/run_<timestamp>/controller_load_test_results.csv
dashboard/scripts/add-result.sh 1.1.0 path/to/webhook.csv webhook
dashboard/scripts/add-result.sh 1.1.0 path/to/backup.csv backup
git add dashboard/results/1.1.0
git commit -m "chore(dashboard): add load test results for 1.1.0"
git push
```

Or in the GitHub web UI: open `dashboard/results`, choose **Add file → Upload files**,
and drag in a folder named after the release that contains the CSVs.

Release names may contain letters, digits, `.`, `_`, `+` and `-`. Releases are
ordered by version (`sort -V`), so `0.9.0` comes before `0.10.0`.

## Previewing locally

```sh
dashboard/scripts/build-site.sh
python3 -m http.server -d dashboard/_site 8000
```

## Layout

```
dashboard/
  site/index.html           the page
  site/vendor/              Chart.js, vendored so the page needs no CDN
  results/<release>/        up to three CSVs per release, one per kind of test
  scripts/build-site.sh     assembles _site/ and writes results/index.json
  scripts/add-result.sh     copies a CSV into results/<release>/ under the right name
```
