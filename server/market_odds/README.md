# Market odds coverage pilot

This module checks whether a bookmaker odds provider can cover the official
lottery match list without silently linking the wrong event.

It audits three pre-match markets:

- `h2h`: European 1X2 odds
- `spreads`: Asian handicap
- `totals`: over/under goals

## Run against The Odds API

Install the optional matching dependency:

```bash
python -m pip install -r requirements.txt
```

Keep the API key outside Git:

```bash
export THE_ODDS_API_KEY='...'
python odds_coverage_audit.py --output coverage.json
```

Alternatively, put only the key in the Git-ignored `.odds-api-key` file:

```bash
python odds_coverage_audit.py \
  --api-key-file .odds-api-key \
  --output coverage-local.json
```

The script never writes the key to its report.

## Acceptance gate

Do not connect the provider to the public App until a multi-day pilot meets
all of these conditions:

- strict event match rate is at least 90%
- complete three-market coverage is at least 85%
- no confirmed cross-match links
- daily request-credit usage stays within the configured budget

`review`, `unmatched`, and `unmapped_league` records must not be exposed as
bookmaker odds in the App.

The provider map is intentionally separate from the existing official match
data. Expand league keys and team aliases only after checking provider event
names from real responses.
