# AfricAir

> Africa-first flight discovery and booking experience — bilingual, currency-aware, and designed around continent-wide journeys.

![AfricAir landing page](docs/images/africair-landing-page.png)

## Overview

AfricAir is a responsive flight booking site. Travellers search any airport in the world, compare outbound and return options, enter passenger details, review the full fare, and confirm. The confirmation creates a booking reference, e-ticket numbers and a downloadable PDF itinerary. **No payment is collected at any point.**

## Features

- **Worldwide coverage**: 4,008 airports with scheduled service in 233 countries and territories, from the [OurAirports](https://ourairports.com/data/) open dataset (public domain). All 247 countries and territories are listed on the Destinations page. Countries without an airport of their own (Monaco, Andorra, Vatican City…) point to their nearest gateways.
- **Airport search** by IATA code, city, airport name or country, in English or French, accent-insensitive, with keyboard navigation.
- **Search**: round trip or one way, 1–9 travellers (adults, children 2–11, infants under 2 on a lap), and four cabins. Dates are validated.
- **Results**: nonstop and connecting itineraries (via real hub airports), with durations based on distance, fares that vary by cabin, a ±3-day fare calendar, sort (best, cheapest, fastest, earliest), a stops filter, and expandable segment details with layovers.
- **Traveller details** with field-level validation: names, age rules per passenger type on the travel date, nationality, and passport/ID valid beyond the last flight. Contact email and phone are collected once per booking.
- **Review and confirm** with a fare breakdown per passenger type, taxes and service fee, and a required confirmation checkbox. No payment step.
- **PDF itinerary** (jsPDF): booking reference, status, every flight segment with airports, times, aircraft and baggage, travellers with e-ticket numbers and masked document numbers, fare summary, and important information. It downloads automatically on confirmation and can be downloaded again at any time.
- **My trips**: bookings are saved in the browser's local storage. Travellers can find a booking by reference and last name, view it, re-download the PDF, cancel it (the PDF is then marked cancelled) or remove it.
- **English / French** throughout, plus **35 display currencies** at indicative rates.
- **Shareable URLs**: a search lives in the URL (`#/flights?from=NBO&to=LOS&depart=…`), the browser back button works, and an in-progress booking survives a page reload.

## Important note

There is no live airline inventory. Schedules and fares are generated deterministically for each route, date and cabin, so the same search always returns the same flights, and they are labelled as indicative. Carriers are fictional. Nothing is ticketed and no payment is taken. Connecting to real inventory (an NDC or GDS provider) would replace `src/lib/flights.ts`.

## Run locally

```bash
pnpm install
pnpm dev            # http://localhost:3000
```

## Quality checks

```bash
pnpm check          # TypeScript
pnpm test           # unit tests (airport data, flight generation, pricing, validation, PDF)
pnpm test:e2e       # Playwright: full booking flows on desktop + mobile (run `npx playwright install chromium` once)
pnpm build
```

## Project structure

```text
src/
  App.tsx                 # Routing, booking state, guards
  i18n.ts                 # English and French strings
  context.ts              # Language, currency and formatting context
  components/             # Header, SearchForm, AirportCombobox, Results, Travellers, Review, Trips, Destinations, Home
  data/airports.json      # Generated airport dataset (do not edit by hand)
  data/airports.ts        # Airport lookup, search, country names
  data/currencies.ts
  lib/flights.ts          # Itinerary generation and pricing
  lib/validation.ts       # Search, passenger and contact rules
  lib/pdf.ts              # PDF itinerary
  lib/bookings.ts         # Local storage persistence, references, e-ticket numbers
  lib/router.ts           # Hash routing and search URL encoding
scripts/build-airports.mjs  # Regenerates airports.json: `pnpm data:airports`
e2e/booking.spec.ts         # End-to-end tests
```

## DevOps bootcamp projects

AfricAir doubles as the sample application for a four-part DevOps bootcamp. Each project has its own brief, acceptance checks, knowledge questions and grading rubric:

| # | Project | Domains |
|---|---|---|
| 1 | [Linux, scripting, the build process & AWS hosting](projects/01-linux-scripting-build-aws/README.md) | Bash, systemd, nginx, EC2, IAM, S3 + CloudFront |
| 2 | [Containerise AfricAir with Docker](projects/02-docker/README.md) | Multi-stage builds, hardening, Compose, scanning, ECR |
| 3 | [CI/CD with GitHub Actions and CircleCI](projects/03-cicd-github-actions-circleci/README.md) | Pipelines, caching, OIDC, build-once/promote, approvals |
| 4 | [Kubernetes on EKS with Terraform, RDS, External Secrets & Ingress](projects/04-kubernetes-eks-terraform/README.md) | Helm, kind, Terraform, EKS, RDS, ESO, ALB Ingress |
