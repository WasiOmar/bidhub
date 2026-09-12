export default function Badge({ tone = 'closed', children }) {
  return <span className={`badge badge-${tone}`}>{children}</span>;
}
