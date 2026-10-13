# AfricAir

> Africa-first flight discovery and booking experience — bilingual, currency-aware, and designed around continent-wide journeys.

![AfricAir landing page](docs/images/africair-landing-page.png)

## Overview

AfricAir is a responsive booking-flow prototype for travel across Africa. It lets travellers search major African airports, compare sample outbound and return itineraries, add traveller details, review a fare in their preferred currency, and download a branded confirmation PDF — without a payment collection step.

## Highlights

- **Africa-wide route discovery** across 55 African countries and territories, with major cities and airport codes in searchable fields.
- **Round-trip and one-way journeys** with selectable outbound and return flight options.
- **English and French UI** throughout the search, booking, review, and confirmation journey.
- **29 currencies**, including African and international currencies, with consistent fare conversion.
- **Traveller validation** for every passenger before the booking review.
- **No-payment confirmation flow**: the final Proceed action creates a reservation reference and PDF itinerary; no card or payment form is collected.
- **Responsive interface** for desktop and mobile.

## Stack

- React 19 + TypeScript
- Vite
- Lucide React icons
- jsPDF for downloadable booking confirmations

## Run locally

```bash
pnpm install
pnpm dev
```

The development server listens on port `3000` by default.

## Quality checks

```bash
pnpm check
pnpm build
```

## Project structure

```text
src/
  App.tsx       # Booking flow, localization, PDF generation, and UI state
  data.ts       # Airport, country, currency, and translation data
  styles.css    # Responsive visual system
public/
  manus-routes.json
  africair-mark.svg
docs/images/
  africair-landing-page.png
```

## Important note

AfricAir currently uses locally generated, route-aware flight examples for the booking experience. Connecting live airline inventory, ticketing, or payment processing would require dedicated provider integrations and production compliance work.
