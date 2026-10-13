import { useState } from 'react'
import { ArrowLeft, ArrowRight, CheckCircle2, CircleAlert, ShieldCheck, Users } from 'lucide-react'
import { useApp } from '../context'
import { countryName } from '../data/airports'
import type { Contact, FareBreakdown, Itinerary, Passenger, SearchParams } from '../lib/types'
import { FareSummary, JourneyHeading, LegCard, Progress } from './Shared'

type Props = {
  search: SearchParams
  outbound: Itinerary
  inbound?: Itinerary
  passengers: Passenger[]
  contact: Contact
  fare: FareBreakdown
  submitting: boolean
  onEditFlights: () => void
  onEditTravellers: () => void
  onConfirm: () => void
}

export function Review({ search, outbound, inbound, passengers, contact, fare, submitting, onEditFlights, onEditTravellers, onConfirm }: Props) {
  const { t } = useApp()
  const [agreed, setAgreed] = useState(false)
  const [showError, setShowError] = useState(false)

  return <main className="booking-shell narrow-shell">
    <Progress step={3} />
    <JourneyHeading title={t.reviewTitle} subtitle={t.reviewSubtitle} />
    <div className="review-layout">
      <section className="review-content">
        <LegCard title={t.outbound} itinerary={outbound} cabin={search.cabin} action={<button className="text-button" onClick={onEditFlights}>{t.changeFlights}</button>} />
        {inbound && <LegCard title={t.return} itinerary={inbound} cabin={search.cabin} action={<button className="text-button" onClick={onEditFlights}>{t.changeFlights}</button>} />}
        <PassengerList passengers={passengers} contact={contact} action={<button className="text-button" onClick={onEditTravellers}>{t.edit}</button>} />
      </section>
      <FareSummary fare={fare}>
        <div className="no-payment-callout"><ShieldCheck size={19} /><div><strong>{t.noPayment}</strong><p>{t.noPaymentCopy}</p></div></div>
        <label className={`agree-line ${showError && !agreed ? 'has-error' : ''}`}>
          <input type="checkbox" checked={agreed} onChange={(event) => { setAgreed(event.target.checked); setShowError(false) }} />
          <span>{t.agree}</span>
        </label>
        {showError && !agreed && <p className="inline-error" role="alert"><CircleAlert size={16} />{t.errAgree}</p>}
        <button className="button button-primary large-button" disabled={submitting} onClick={() => (agreed ? onConfirm() : setShowError(true))}>{t.confirmBooking}<ArrowRight size={17} /></button>
        <button className="back-link" onClick={onEditTravellers}><ArrowLeft size={15} />{t.back}</button>
      </FareSummary>
    </div>
  </main>
}

export function PassengerList({ passengers, contact, action }: { passengers: (Passenger & { ticketNumber?: string })[]; contact: Contact; action?: React.ReactNode }) {
  const { t, language, date } = useApp()
  return <article className="review-card travellers-review">
    <div className="review-card-head">
      <div><span className="eyebrow"><Users size={14} />{t.bookedFor}</span><h2>{passengers.length} {passengers.length === 1 ? t.traveller : t.travellersPlural}</h2></div>
      {action}
    </div>
    {passengers.map((person, index) => <div className="person-row" key={index}>
      <span>{index + 1}</span>
      <div>
        <strong>{person.lastName.toUpperCase()}, {person.firstName} <em>· {t[person.type]}</em></strong>
        <small>{date(person.dob, 'numeric')} · {countryName(person.nationality, language)} · {person.documentNumber.toUpperCase()}{person.ticketNumber && ` · ${t.ticket} ${person.ticketNumber}`}</small>
      </div>
      <CheckCircle2 size={18} />
    </div>)}
    <div className="contact-row"><strong>{t.contact}</strong><span>{contact.email} · {contact.phone}</span></div>
  </article>
}
