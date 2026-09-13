export default function SqlNote({ view, children }) {
  return (
    <div className="sql-note">
      <span className="sql-tag">SQL</span>
      <code className="sql-code">{children}</code>
      <span className="sql-view">{view}</span>
    </div>
  );
}
