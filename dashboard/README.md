# Load test dashboard

A static page with one chart per metric: the metric's value on the y axis and the
releases, oldest to newest, on the x axis. It shows the last 5 releases by default. It is published to GitHub Pages by
`.github/workflows/publish-dashboard.yml` on every push to `main` that touches
`dashboard/`.

## One-time setup

In the repository settings, open **Pages** and set **Source** to **GitHub Actions**.

## Adding a release

Put the CSV at `dashboard/results/<release>/controller_load_test_results.csv` and push.

```sh
dashboard/scripts/add-result.sh 0.41.0 outputs/run_<timestamp>/controller_load_test_results.csv
git add dashboard/results/0.41.0
git commit -m "Add load test results for 0.41.0"
git push
```

Or in the GitHub web UI: open `dashboard/results`, choose **Add file → Upload files**,
and drag in a folder named after the release that contains the CSV.

Release names may contain letters, digits, `.`, `_`, `+` and `-`. Releases are
ordered by version (`sort -V`), so `0.9.0` comes before `0.10.0`.

`results/sample` holds one example run. Rename it to the release it belongs to (for
example `0.41.0`) or delete it: a name that is not a version sorts after the real releases.

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
  results/<release>/        one CSV per release
  scripts/build-site.sh     assembles _site/ and writes results/index.json
  scripts/add-result.sh     copies a CSV into results/<release>/
```
