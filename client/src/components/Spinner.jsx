export default function Spinner({ label = 'Loading…' }) {
  return (
    <div className="spinner-container" role="status" aria-live="polite">
      <span className="spinner" aria-hidden="true" />
      <span>{label}</span>
    </div>
  );
}
