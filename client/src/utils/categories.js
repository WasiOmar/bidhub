const ROOT_ICONS = {
  'art-collectibles': '🎨',
  books: '📚',
  electronics: '💻',
  'musical-instruments': '🎸',
  vehicles: '🚗',
};

// Dark-mode categorical palette, validated for colour-blind separation on the card surface.
// Assigned by root order, never cycled: roots past the eighth fall back to neutral grey.
const ROOT_COLORS = ['#3987e5', '#d95926', '#199e70', '#c98500', '#d55181', '#008300', '#9085e9', '#e66767'];

export function indexCategories(tree) {
  const index = new Map();

  tree.forEach((root, i) => {
    const rootInfo = {
      name: root.name,
      icon: ROOT_ICONS[root.slug] || '📦',
      color: ROOT_COLORS[i] || '#6b7280',
    };
    const walk = (node) => {
      index.set(node.category_id, { name: node.name, root: rootInfo });
      node.children.forEach(walk);
    };
    walk(root);
  });

  return index;
}
