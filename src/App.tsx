import { FormEvent, useEffect, useMemo, useState } from 'react'
import { jsPDF } from 'jspdf'
import {
  ArrowLeft, ArrowRight, CalendarDays, Check, CheckCircle2, ChevronDown,
  CircleAlert, Clock3, Download, Globe2, Luggage, MapPin, Menu, Minus,
  Plane, Plus, Route, ShieldCheck, Sparkles, Star, Users, X,
} from 'lucide-react'
import { AFRICAN_COUNTRIES, AIRPORTS, CURRENCIES, TRANSLATIONS, type Airport } from './data'

type Language = 'en' | 'fr'
type View = 'search' | 'results' | 'travellers' | 'review' | 'confirmation'
type Flight = {
  id: string
  airline: string
  code: string
  depart: string
  arrive: string
  duration: string
  stops: number
  basePrice: number
  badge?: string
}
type Passenger = { name: string; email: string; phone: string; dob: string; document: string }

const initialDate = new Date(Date.now() + 1000 * 60 * 60 * 24 * 14).toISOString().slice(0, 10)
const returnDate = new Date(Date.now() + 1000 * 60 * 60 * 24 * 19).toISOString().slice(0, 10)
const emptyPassenger = (): Passenger => ({ name: '', email: '', phone: '', dob: '', document: '' })

const airportDisplay = (airport: Airport) => `${airport.city} (${airport.code})`

function AirportCombobox({ value, onChange, label, country }: { value: string; onChange: (value: string) => void; label: string; country: string }) {
  const selected = AIRPORTS.find((airport) => airport.code === value) ?? AIRPORTS[0]
  const [query, setQuery] = useState(airportDisplay(selected))
  const listId = `airport-options-${label.replace(/[^a-z]/gi, '').toLowerCase()}`

  useEffect(() => setQuery(airportDisplay(selected)), [selected.code])

  return <label className="field airport-field">
    <span className="field-label"><MapPin size={15} aria-hidden="true" /> {label}</span>
    <input list={listId} value={query} onChange={(event) => {
      const nextQuery = event.target.value
      setQuery(nextQuery)
      const matchingAirport = AIRPORTS.find((airport) => airportDisplay(airport).toLowerCase() === nextQuery.toLowerCase())
      if (matchingAirport) onChange(matchingAirport.code)
    }} onBlur={() => setQuery(airportDisplay(selected))} aria-label={label} />
    <datalist id={listId}>{AFRICAN_COUNTRIES.map((countryName) => AIRPORTS.filter((airport) => airport.country === countryName).map((airport) => <option key={airport.code} value={airportDisplay(airport)} label={airport.country} />))}</datalist>
    <span className="city-caption">{country}</span>
  </label>
}

function buildFlightOptions(origin: Airport, destination: Airport, leg: 'outbound' | 'return'): Flight[] {
  const seed = [...origin.code, ...destination.code].reduce((total, character) => total + character.charCodeAt(0), 0) + (leg === 'return' ? 37 : 0)
  const carriers = ['Kora Air', 'Baobab Connect', 'Atlas Africa']
  const prefixes = ['KA', 'BC', 'AA']
  const starts = [7, 11, 17]
  return carriers.map((airline, index) => {
    const durationMinutes = 150 + ((seed + index * 31) % 190)
    const totalMinutes = starts[index] * 60 + ((seed + index * 13) % 3) * 10 + durationMinutes
    const departureMinutes = starts[index] * 60 + ((seed + index * 13) % 3) * 10
    const time = (minutes: number) => `${String(Math.floor((minutes % 1440) / 60)).padStart(2, '0')}:${String(minutes % 60).padStart(2, '0')}`
    return {
      id: `${leg}-${index}`,
      airline,
      code: `${prefixes[index]} ${100 + ((seed + index * 47) % 800)}`,
      depart: time(departureMinutes),
      arrive: time(totalMinutes),
      duration: `${Math.floor(durationMinutes / 60)}h ${durationMinutes % 60}m`,
      stops: index === 1 ? 1 : 0,
      basePrice: 220 + ((seed + index * 43) % 125),
      badge: index === 0 ? 'value' : index === 2 ? 'fast' : undefined,
    }
  })
}

function App() {
  const [language, setLanguage] = useState<Language>('en')
  const [currencyCode, setCurrencyCode] = useState('USD')
  const [view, setView] = useState<View>('search')
  const [navOpen, setNavOpen] = useState(false)
  const [tripType, setTripType] = useState<'round' | 'oneway'>('round')
  const [from, setFrom] = useState('NBO')
  const [to, setTo] = useState('LOS')
  const [departDate, setDepartDate] = useState(initialDate)
  const [backDate, setBackDate] = useState(returnDate)
  const [passengerCount, setPassengerCount] = useState(1)
  const [cabin, setCabin] = useState('Economy')
  const [error, setError] = useState('')
  const [selectedFlightId, setSelectedFlightId] = useState('outbound-0')
  const [selectedReturnFlightId, setSelectedReturnFlightId] = useState('return-0')
  const [passengers, setPassengers] = useState<Passenger[]>([emptyPassenger()])
  const [reservation, setReservation] = useState('')
  const [pdfReady, setPdfReady] = useState(false)

  const t = TRANSLATIONS[language]
  const currency = CURRENCIES.find((item) => item.code === currencyCode) ?? CURRENCIES[0]
  const airportByCode = useMemo(() => new Map(AIRPORTS.map((airport) => [airport.code, airport])), [])
  const fromAirport = airportByCode.get(from) ?? AIRPORTS[0]
  const toAirport = airportByCode.get(to) ?? AIRPORTS[1]
  const locale = language === 'fr' ? 'fr-FR' : 'en-GB'
  const formatMoney = (amount: number) => new Intl.NumberFormat(locale, {
    style: 'currency', currency: currency.code, maximumFractionDigits: currency.code === 'JPY' ? 0 : 2,
  }).format(amount * currency.rate)
  const formatDate = (value: string) => new Intl.DateTimeFormat(locale, {
    weekday: 'short', day: 'numeric', month: 'short', year: 'numeric',
  }).format(new Date(`${value}T12:00:00`))

  const outboundFlights = buildFlightOptions(fromAirport, toAirport, 'outbound')
  const returnFlights = buildFlightOptions(toAirport, fromAirport, 'return')
  const selectedFlight = outboundFlights.find((flight) => flight.id === selectedFlightId) ?? outboundFlights[0]
  const selectedReturnFlight = returnFlights.find((flight) => flight.id === selectedReturnFlightId) ?? returnFlights[0]
  const baseFare = (selectedFlight.basePrice + (tripType === 'round' ? selectedReturnFlight.basePrice : 0)) * passengerCount
  const taxes = 54 * passengerCount
  const serviceFee = 18
  const total = baseFare + taxes + serviceFee

  const changePassengerCount = (next: number) => {
    const safeCount = Math.max(1, Math.min(9, next))
    setPassengerCount(safeCount)
    setPassengers((current) => {
      if (safeCount > current.length) return [...current, ...Array.from({ length: safeCount - current.length }, emptyPassenger)]
      return current.slice(0, safeCount)
    })
  }

  const onSearch = (event: FormEvent) => {
    event.preventDefault()
    if (from === to) {
      setError(t.validationRoute)
      return
    }
    setError('')
    setView('results')
    window.setTimeout(() => document.getElementById('flight-results')?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 0)
  }

  const goToTravellers = () => {
    setError('')
    setView('travellers')
    window.scrollTo({ top: 0, behavior: 'smooth' })
  }

  const updatePassenger = (index: number, key: keyof Passenger, value: string) => {
    setPassengers((current) => current.map((person, personIndex) => personIndex === index ? { ...person, [key]: value } : person))
  }

  const goToReview = (event: FormEvent) => {
    event.preventDefault()
    const complete = passengers.every((person) => person.name.trim() && person.email.includes('@') && person.phone.trim() && person.dob && person.document.trim())
    if (!complete) {
      setError(t.validationPassenger)
      return
    }
    setError('')
    setView('review')
    window.scrollTo({ top: 0, behavior: 'smooth' })
  }

  const makeReference = () => `AF-${new Date().getFullYear().toString().slice(-2)}${Math.floor(Math.random() * 9000 + 1000)}-${from}${to}`

  const generatePdf = (reference = reservation || makeReference()) => {
    const doc = new jsPDF({ unit: 'pt', format: 'a4' })
    const firstGuest = passengers[0]?.name || (language === 'fr' ? 'Voyageur AfricAir' : 'AfricAir traveller')
    const usableWidth = 515
    doc.setFillColor(11, 91, 90)
    doc.rect(0, 0, 595, 142, 'F')
    doc.setTextColor(244, 201, 93)
    doc.setFont('helvetica', 'bold')
    doc.setFontSize(29)
    doc.text('AfricAir', 42, 64)
    doc.setFontSize(10)
    doc.setTextColor(255, 255, 255)
    doc.text(language === 'fr' ? 'CONFIRMATION DE RÉSERVATION' : 'BOOKING CONFIRMATION', 42, 91)
    doc.setFontSize(13)
    doc.text(`${language === 'fr' ? 'Référence' : 'Reference'}: ${reference}`, 42, 115)

    doc.setTextColor(27, 38, 45)
    doc.setFont('helvetica', 'bold')
    doc.setFontSize(18)
    doc.text(`${fromAirport.city}  →  ${toAirport.city}`, 42, 187)
    doc.setFont('helvetica', 'normal')
    doc.setFontSize(11)
    doc.setTextColor(86, 96, 103)
    doc.text(`${formatDate(departDate)}${tripType === 'round' ? `  •  ${formatDate(backDate)}` : ''}`, 42, 211)

    doc.setDrawColor(217, 225, 223)
    doc.line(42, 236, 553, 236)
    doc.setTextColor(27, 38, 45)
    doc.setFont('helvetica', 'bold')
    doc.setFontSize(12)
    doc.text(language === 'fr' ? 'VOL SÉLECTIONNÉ' : 'SELECTED FLIGHT', 42, 265)
    doc.setFont('helvetica', 'normal')
    doc.setFontSize(11)
    doc.text(`${selectedFlight.airline} • ${selectedFlight.code} • ${selectedFlight.depart} – ${selectedFlight.arrive}`, 42, 289)
    if (tripType === 'round') doc.text(`${t.return}: ${selectedReturnFlight.airline} • ${selectedReturnFlight.code} • ${selectedReturnFlight.depart} – ${selectedReturnFlight.arrive}`, 42, 309)
    const flightDetailOffset = tripType === 'round' ? 20 : 0
    doc.text(`${selectedFlight.duration} • ${selectedFlight.stops === 0 ? t.nonstop : `${selectedFlight.stops} ${t.stops}`} • ${cabin}`, 42, 309 + flightDetailOffset)

    doc.setFont('helvetica', 'bold')
    doc.setFontSize(12)
    const travellersY = 352 + flightDetailOffset
    doc.text(language === 'fr' ? 'VOYAGEURS' : 'TRAVELLERS', 42, travellersY)
    doc.setFont('helvetica', 'normal')
    passengers.forEach((person, index) => {
      doc.text(`${index + 1}. ${person.name || firstGuest}`, 42, travellersY + 24 + index * 21)
    })

    const pricingY = 405 + flightDetailOffset + passengers.length * 21
    doc.setDrawColor(217, 225, 223)
    doc.line(42, pricingY, 553, pricingY)
    doc.setFont('helvetica', 'bold')
    doc.setFontSize(12)
    doc.text(language === 'fr' ? 'RÉCAPITULATIF DU TARIF' : 'FARE SUMMARY', 42, pricingY + 29)
    doc.setFont('helvetica', 'normal')
    doc.setFontSize(11)
    doc.text(`${t.baseFare}: ${formatMoney(baseFare)}`, 42, pricingY + 52)
    doc.text(`${t.taxes}: ${formatMoney(taxes)}`, 42, pricingY + 73)
    doc.text(`${t.service}: ${formatMoney(serviceFee)}`, 42, pricingY + 94)
    doc.setFont('helvetica', 'bold')
    doc.setFontSize(14)
    doc.text(`${t.total}: ${formatMoney(total)}`, 42, pricingY + 125)

    doc.setFillColor(247, 250, 249)
    doc.roundedRect(42, pricingY + 153, usableWidth, 72, 12, 12, 'F')
    doc.setTextColor(11, 91, 90)
    doc.setFont('helvetica', 'bold')
    doc.setFontSize(11)
    doc.text(language === 'fr' ? 'AUCUN PAIEMENT COLLECTÉ' : 'NO PAYMENT COLLECTED', 60, pricingY + 180)
    doc.setFont('helvetica', 'normal')
    doc.setTextColor(86, 96, 103)
    doc.setFontSize(10)
    const note = language === 'fr'
      ? 'Cette confirmation résume la réservation créée dans AfricAir. Conservez-la dans vos dossiers.'
      : 'This confirmation summarises the reservation created in AfricAir. Keep it with your travel records.'
    doc.text(doc.splitTextToSize(note, 470), 60, pricingY + 202)
    doc.save(`AfricAir-${reference}.pdf`)
    setPdfReady(true)
  }

  const proceed = () => {
    const reference = makeReference()
    setReservation(reference)
    setView('confirmation')
    window.scrollTo({ top: 0, behavior: 'smooth' })
    window.setTimeout(() => generatePdf(reference), 200)
  }

  const resetBooking = () => {
    setView('search')
    setPassengers([emptyPassenger()])
    setPassengerCount(1)
    setReservation('')
    setPdfReady(false)
    setError('')
    window.scrollTo({ top: 0, behavior: 'smooth' })
  }

  const Progress = () => {
    const active = view === 'results' ? 1 : view === 'travellers' ? 2 : view === 'review' ? 3 : view === 'confirmation' ? 4 : 0
    const steps = [t.searchFlights, t.seat, t.travelerDetails, t.confirmation]
    return (
      <div className="progress-wrap" aria-label="Booking progress">
        <div className="progress-steps">
          {steps.map((label, index) => <div className={`progress-step ${active >= index + 1 ? 'is-done' : ''} ${active === index + 1 ? 'is-active' : ''}`} key={label}>
            <span>{active > index + 1 ? <Check size={13} /> : index + 1}</span><small>{label}</small>
          </div>)}
        </div>
      </div>
    )
  }

  const Header = () => (
    <header className="site-header">
      <a className="brand" href="#top" onClick={(event) => { event.preventDefault(); resetBooking() }} aria-label="AfricAir home">
        <span className="brand-mark"><Plane size={19} strokeWidth={2.4} /></span><span className="brand-name">Afric<span>Air</span></span>
      </a>
      <button className="mobile-menu" onClick={() => setNavOpen(!navOpen)} aria-label="Toggle menu">{navOpen ? <X /> : <Menu />}</button>
      <nav className={navOpen ? 'is-open' : ''}>
        <a href="#discover" onClick={() => setNavOpen(false)}>{t.navExplore}</a>
        <button type="button" onClick={() => { if (reservation) setView('confirmation'); else { setView('search'); setError(language === 'fr' ? 'Aucune réservation active dans ce navigateur.' : 'No active reservation in this browser.') }; setNavOpen(false) }}>{t.navManage}</button>
        <a href="mailto:support@africair.example" onClick={() => setNavOpen(false)}>{t.navHelp}</a>
      </nav>
      <div className="header-controls">
        <label className="compact-select"><Globe2 size={15} /><span className="sr-only">{t.language}</span><select value={language} onChange={(event) => setLanguage(event.target.value as Language)}><option value="en">EN</option><option value="fr">FR</option></select><ChevronDown size={13} /></label>
        <label className="compact-select currency-select"><span className="sr-only">{t.currency}</span><select value={currencyCode} onChange={(event) => setCurrencyCode(event.target.value)}>{CURRENCIES.map((item) => <option key={item.code} value={item.code}>{item.code}</option>)}</select><ChevronDown size={13} /></label>
      </div>
    </header>
  )

  const SearchForm = () => <form className="search-panel" onSubmit={onSearch}>
    <div className="trip-switch" role="group" aria-label="Trip type">
      <button type="button" className={tripType === 'round' ? 'active' : ''} onClick={() => setTripType('round')}><span className="radio-dot" />{t.roundTrip}</button>
      <button type="button" className={tripType === 'oneway' ? 'active' : ''} onClick={() => setTripType('oneway')}><span className="radio-dot" />{t.oneWay}</button>
    </div>
    <div className="search-fields">
      <AirportCombobox value={from} onChange={setFrom} label={t.from} country={fromAirport.country} />
      <button className="swap-button" type="button" onClick={() => { const currentFrom = from; setFrom(to); setTo(currentFrom) }} aria-label="Swap origin and destination"><Route size={17} /></button>
      <AirportCombobox value={to} onChange={setTo} label={t.to} country={toAirport.country} />
      <label className="field date-field"><span className="field-label"><CalendarDays size={15} aria-hidden="true" /> {t.departure}</span><input type="date" value={departDate} min={new Date().toISOString().slice(0, 10)} onChange={(event) => setDepartDate(event.target.value)} /><span className="city-caption">{formatDate(departDate)}</span></label>
      {tripType === 'round' && <label className="field date-field"><span className="field-label"><CalendarDays size={15} aria-hidden="true" /> {t.return}</span><input type="date" value={backDate} min={departDate} onChange={(event) => setBackDate(event.target.value)} /><span className="city-caption">{formatDate(backDate)}</span></label>}
      <div className="field traveller-field"><span className="field-label"><Users size={15} aria-hidden="true" /> {t.travellers}</span><div className="quantity-row"><button type="button" onClick={() => changePassengerCount(passengerCount - 1)} disabled={passengerCount === 1} aria-label="Remove traveller"><Minus size={14} /></button><strong>{passengerCount}</strong><button type="button" onClick={() => changePassengerCount(passengerCount + 1)} aria-label="Add traveller"><Plus size={14} /></button></div><span className="city-caption">{passengerCount} {passengerCount === 1 ? t.traveller : t.travellersPlural}</span></div>
      <label className="field cabin-field"><span className="field-label"><Sparkles size={15} aria-hidden="true" /> {t.cabin}</span><select value={cabin} onChange={(event) => setCabin(event.target.value)}><option value="Economy">{t.economy}</option><option value="Premium Economy">{t.premium}</option><option value="Business">{t.business}</option><option value="First">{t.first}</option></select><span className="city-caption">{cabin === 'Economy' ? t.economy : cabin === 'Business' ? t.business : cabin === 'First' ? t.first : t.premium}</span></label>
    </div>
    {error && <p className="inline-error"><CircleAlert size={16} />{error}</p>}
    <button className="button button-primary search-submit" type="submit"><Plane size={17} />{t.searchFlights}<ArrowRight size={16} /></button>
  </form>

  const JourneyHeader = ({ title, subtitle }: { title: string; subtitle: string }) => <>
    <Progress />
    <section className="journey-heading"><span className="eyebrow"><Sparkles size={14} /> AFRICAIR</span><h1>{title}</h1><p>{subtitle}</p></section>
  </>

  const FlightCard = ({ flight, origin, destination, chosen, onSelect }: { flight: Flight; origin: Airport; destination: Airport; chosen: boolean; onSelect: () => void }) => <article className={`flight-card ${chosen ? 'selected' : ''}`}>
    <div className="airline-cell"><div className="airline-symbol">{flight.airline.split(' ').map((word) => word[0]).join('')}</div><div><strong>{flight.airline}</strong><small>{flight.code}</small></div></div>
    <div className="time-cell"><strong>{flight.depart}</strong><small>{origin.code}</small></div>
    <div className="route-line"><span /><div><small>{flight.duration}</small><b>{flight.stops === 0 ? t.nonstop : `${flight.stops} ${t.stops}`}</b></div><span /></div>
    <div className="time-cell arrive"><strong>{flight.arrive}</strong><small>{destination.code}</small></div>
    <div className="price-cell">{flight.badge && <span className="badge">{flight.badge === 'value' ? (language === 'fr' ? 'Meilleur choix' : 'Best value') : (language === 'fr' ? 'Le plus rapide' : 'Fastest')}</span>}<strong>{formatMoney(flight.basePrice)}</strong><small>{language === 'fr' ? 'par voyageur' : 'per traveller'}</small></div>
    <button className={`select-button ${chosen ? 'is-selected' : ''}`} onClick={onSelect}>{chosen ? <><CheckCircle2 size={17} />{t.selected}</> : t.selectFlight}</button>
    <div className="fare-notes"><span><Luggage size={14} />{t.carryOn}</span><span><ShieldCheck size={14} />{t.changeable}</span></div>
  </article>

  const ResultPage = () => <main className="booking-shell" id="flight-results">
    <JourneyHeader title={t.searchResults} subtitle={t.chooseFlight} />
    <div className="route-summary"><div><small>{t.from}</small><strong>{fromAirport.city} <em>{fromAirport.code}</em></strong></div><Route size={19} /><div><small>{t.to}</small><strong>{toAirport.city} <em>{toAirport.code}</em></strong></div><span className="summary-date">{formatDate(departDate)} <b>·</b> {passengerCount} {passengerCount === 1 ? t.traveller : t.travellersPlural}</span><button onClick={() => setView('search')} className="text-button">{t.searchFlights}</button></div>
    <div className="result-layout"><aside className="filter-card"><div className="filter-icon"><Sparkles size={18} /></div><h3>{t.filters}</h3><p>{t.clearPrices}</p><div className="currency-note"><span>{currency.code}</span><small>{currency.label}</small></div><div className="filter-note"><ShieldCheck size={17} />{t.secure}</div></aside>
      <section className="flights-list"><div className="leg-heading"><span>{t.departure}</span><strong>{fromAirport.city} <ArrowRight size={13} /> {toAirport.city} · {formatDate(departDate)}</strong></div>{outboundFlights.map((flight) => <FlightCard key={flight.id} flight={flight} origin={fromAirport} destination={toAirport} chosen={selectedFlightId === flight.id} onSelect={() => setSelectedFlightId(flight.id)} />)}
        {tripType === 'round' && <><div className="leg-heading return-leg"><span>{t.return}</span><strong>{toAirport.city} <ArrowRight size={13} /> {fromAirport.city} · {formatDate(backDate)}</strong></div>{returnFlights.map((flight) => <FlightCard key={flight.id} flight={flight} origin={toAirport} destination={fromAirport} chosen={selectedReturnFlightId === flight.id} onSelect={() => setSelectedReturnFlightId(flight.id)} />)}</>}
      </section>
    </div>
    <div className="sticky-continue"><div><span>{t.selectedFlight}</span><strong>{selectedFlight.airline} · {selectedFlight.depart} — {selectedFlight.arrive}{tripType === 'round' && ` · ${t.return}: ${selectedReturnFlight.depart} — ${selectedReturnFlight.arrive}`}</strong></div><div><strong>{formatMoney(selectedFlight.basePrice + (tripType === 'round' ? selectedReturnFlight.basePrice : 0))} <small>{language === 'fr' ? 'par voyageur' : 'per traveller'}</small></strong><button className="button button-primary" onClick={goToTravellers}>{t.continue}<ArrowRight size={16} /></button></div></div>
  </main>

  const TravellerPage = () => <main className="booking-shell narrow-shell">
    <JourneyHeader title={t.travelerDetails} subtitle={t.travelerSubtitle} />
    <div className="traveller-layout"><form className="traveller-form" onSubmit={goToReview}>{passengers.map((person, index) => <fieldset key={index}><legend><span>{index + 1}</span>{t.adult} {index + 1}</legend><div className="field-grid"><label className="form-field wide"><span>{t.fullName} <b>{t.required}</b></span><input placeholder={language === 'fr' ? 'Nom tel qu’il apparaît sur le document' : 'Name as shown on travel document'} value={person.name} onChange={(event) => updatePassenger(index, 'name', event.target.value)} required /></label><label className="form-field"><span>{t.email} <b>{t.required}</b></span><input type="email" placeholder="name@example.com" value={person.email} onChange={(event) => updatePassenger(index, 'email', event.target.value)} required /></label><label className="form-field"><span>{t.phone} <b>{t.required}</b></span><input type="tel" placeholder="+254 700 000 000" value={person.phone} onChange={(event) => updatePassenger(index, 'phone', event.target.value)} required /></label><label className="form-field"><span>{t.dateOfBirth} <b>{t.required}</b></span><input type="date" value={person.dob} onChange={(event) => updatePassenger(index, 'dob', event.target.value)} required /></label><label className="form-field"><span>{t.document} <b>{t.required}</b></span><input placeholder="A1234567" value={person.document} onChange={(event) => updatePassenger(index, 'document', event.target.value)} required /></label></div></fieldset>)}
      {error && <p className="inline-error"><CircleAlert size={16} />{error}</p>}
      <div className="form-actions"><button type="button" className="button button-ghost" onClick={() => setView('results')}><ArrowLeft size={16} />{t.back}</button><button className="button button-primary" type="submit">{t.saveContinue}<ArrowRight size={16} /></button></div>
    </form><aside className="mini-itinerary"><span className="eyebrow"><Route size={14} />{t.summary}</span><h3>{fromAirport.city} <ArrowRight size={17} /> {toAirport.city}</h3><p>{formatDate(departDate)}{tripType === 'round' && ` · ${formatDate(backDate)}`}</p><div><Plane size={16} /><span>{selectedFlight.airline}<small>{selectedFlight.code} · {selectedFlight.duration}</small></span></div><strong>{formatMoney(total)}</strong></aside></div>
  </main>

  const ReviewPage = () => <main className="booking-shell narrow-shell">
    <JourneyHeader title={t.reviewBooking} subtitle={t.reviewSubtitle} />
    <div className="review-layout"><section className="review-content"><article className="review-card"><div className="review-card-head"><div><span className="eyebrow"><Plane size={14} />{t.itinerary}</span><h2>{fromAirport.city} <ArrowRight size={18} /> {toAirport.city}</h2></div><button className="text-button" onClick={() => setView('results')}>{t.searchFlights}</button></div><div className="itinerary-timeline"><div><span className="time-dot" /><strong>{selectedFlight.depart}</strong><p>{fromAirport.city}<small>{fromAirport.code} · {fromAirport.country}</small></p></div><div className="duration-line"><small>{selectedFlight.duration}</small><span /><small>{selectedFlight.stops === 0 ? t.nonstop : `${selectedFlight.stops} ${t.stops}`}</small></div><div><span className="time-dot end" /><strong>{selectedFlight.arrive}</strong><p>{toAirport.city}<small>{toAirport.code} · {toAirport.country}</small></p></div></div><div className="flight-detail-strip"><div><strong>{selectedFlight.airline}</strong><small>{selectedFlight.code}</small></div><div><strong>{formatDate(departDate)}</strong><small>{cabin}</small></div><div><strong>{passengerCount}</strong><small>{t.travellers}</small></div></div>{tripType === 'round' && <div className="return-flight-strip"><span>{t.return} · {formatDate(backDate)}</span><strong>{toAirport.city} <ArrowRight size={13} /> {fromAirport.city}</strong><small>{selectedReturnFlight.airline} · {selectedReturnFlight.code} · {selectedReturnFlight.depart} — {selectedReturnFlight.arrive}</small></div>}</article>
      <article className="review-card travellers-review"><div className="review-card-head"><div><span className="eyebrow"><Users size={14} />{t.bookedFor}</span><h2>{passengers.length} {passengers.length === 1 ? t.traveller : t.travellersPlural}</h2></div><button className="text-button" onClick={() => setView('travellers')}>{t.travelerDetails}</button></div>{passengers.map((person, index) => <div className="person-row" key={index}><span>{index + 1}</span><div><strong>{person.name}</strong><small>{person.email} · {person.document}</small></div><CheckCircle2 size={18} /></div>)}</article></section>
      <aside className="price-summary"><span className="eyebrow"><Star size={14} />{t.fareBreakdown}</span><h2>{t.summary}</h2><div className="price-line"><span>{t.baseFare}</span><strong>{formatMoney(baseFare)}</strong></div><div className="price-line"><span>{t.taxes}</span><strong>{formatMoney(taxes)}</strong></div><div className="price-line"><span>{t.service}</span><strong>{formatMoney(serviceFee)}</strong></div><div className="price-total"><span>{t.total}</span><strong>{formatMoney(total)}</strong></div><div className="no-payment-callout"><ShieldCheck size={19} /><div><strong>{t.noPayment}</strong><p>{t.noPaymentCopy}</p></div></div><button className="button button-primary large-button" onClick={proceed}>{t.proceed}<ArrowRight size={17} /></button><button className="back-link" onClick={() => setView('travellers')}><ArrowLeft size={15} />{t.back}</button></aside>
    </div>
  </main>

  const ConfirmationPage = () => <main className="booking-shell confirmation-shell"><Progress /><section className="confirmation-card"><div className="success-orb"><Check size={34} /></div><span className="eyebrow"><Sparkles size={14} />AFRICAIR</span><h1>{t.bookingComplete}</h1><p>{t.confirmationText}</p><div className="reference-box"><span>{t.reference}</span><strong>{reservation}</strong></div><div className="confirmation-route"><div><span>{fromAirport.code}</span><strong>{fromAirport.city}</strong></div><Plane size={24} /><div><span>{toAirport.code}</span><strong>{toAirport.city}</strong></div></div><div className="confirmation-details"><div><CalendarDays size={17} /><span>{formatDate(departDate)}{tripType === 'round' && ` · ${formatDate(backDate)}`}</span></div><div><Users size={17} /><span>{passengerCount} {passengerCount === 1 ? t.traveller : t.travellersPlural}</span></div><div><CheckCircle2 size={17} /><span>{formatMoney(total)}</span></div></div><button className="button button-primary download-button" onClick={() => generatePdf()}><Download size={18} />{t.downloadPdf}</button><span className="pdf-status">{pdfReady ? <><CheckCircle2 size={14} />{t.confirmation}</> : t.processing}</span><button className="text-button start-over" onClick={resetBooking}>{t.returnHome}<ArrowRight size={15} /></button></section></main>

  return <div className="app-shell" id="top">
    <Header />
    {view === 'search' && <>
      <main>
        <section className="hero"><div className="hero-copy"><span className="eyebrow light"><Sparkles size={14} />{t.flyAfrica}</span><h1>{t.heroTitle}</h1><p>{t.heroText}</p><div className="hero-trust"><span><ShieldCheck size={17} />{t.support}</span><span><CheckCircle2 size={17} />{t.clearPrices}</span></div></div><div className="hero-art" aria-hidden="true"><div className="orbit orbit-one" /><div className="orbit orbit-two" /><div className="sun" /><div className="continent-shape" /><div className="plane-trail"><Plane size={28} /></div><div className="place-marker marker-a"><MapPin size={15} /></div><div className="place-marker marker-b"><MapPin size={15} /></div></div></section>
        <div className="search-wrap"><SearchForm /><p className="search-note"><MapPin size={15} />{t.routeHint}</p></div>
        <section className="benefit-strip" id="discover"><div className="benefit-title"><span className="eyebrow"><Sparkles size={14} />AFRICAIR</span><h2>{t.reliableRoutes}</h2></div><article><span className="benefit-icon"><Star size={19} /></span><div><strong>{t.directSearch}</strong><p>{t.directSearchCopy}</p></div></article><article><span className="benefit-icon"><Globe2 size={19} /></span><div><strong>{t.countryCoverage}</strong><p>{t.countryCoverageCopy}</p></div></article><article><span className="benefit-icon"><Globe2 size={19} /></span><div><strong>{t.bilingual}</strong><p>{t.bilingualCopy}</p></div></article></section>
        <section className="lower-banner"><div><span className="eyebrow light"><Plane size={14} />AFRICAIR NETWORK</span><h2>{t.lowerTitle}</h2><p>{t.lowerText}</p></div><div className="route-marks"><span>CAI</span><i /><span>NBO</span><i /><span>LOS</span><i /><span>CPT</span></div></section>
      </main>
      <footer><span className="brand"><span className="brand-mark"><Plane size={16} /></span><span className="brand-name">Afric<span>Air</span></span></span><span>© 2026 AfricAir</span><span>{AFRICAN_COUNTRIES.length} {language === 'fr' ? 'pays et territoires africains' : 'African countries & territories'}</span></footer>
    </>}
    {view === 'results' && <ResultPage />}
    {view === 'travellers' && <TravellerPage />}
    {view === 'review' && <ReviewPage />}
    {view === 'confirmation' && <ConfirmationPage />}
  </div>
}

export default App
