function parseTags(raw) {
  return [...new Set(String(raw || '').split(',').map((tag) => tag.trim()).filter(Boolean))];
}

function byTitle(a, b) {
  return a.title.localeCompare(b.title);
}

function buildChildrenMap(documents) {
  const map = new Map();
  for (const doc of documents) {
    const key = doc.parentId || null;
    if (!map.has(key)) map.set(key, []);
    map.get(key).push(doc);
  }

  for (const docs of map.values()) {
    docs.sort(byTitle);
  }

  return map;
}

function collectDescendants(documents, documentId, set = new Set()) {
  for (const doc of documents) {
    if (doc.parentId === documentId) {
      set.add(doc.id);
      collectDescendants(documents, doc.id, set);
    }
  }
  return set;
}

export function createDocumentsModule({ state, api, applyServerResult, setMessage }) {
  const createForm = document.getElementById('doc-create-form');
  const createTitle = document.getElementById('doc-create-title');
  const createParent = document.getElementById('doc-create-parent');
  const createCategory = document.getElementById('doc-create-category');
  const createTags = document.getElementById('doc-create-tags');

  const filterCategory = document.getElementById('doc-filter-category');
  const filterTag = document.getElementById('doc-filter-tag');

  const tree = document.getElementById('doc-tree');

  const editorForm = document.getElementById('doc-editor-form');
  const editorId = document.getElementById('doc-editor-id');
  const editorTitle = document.getElementById('doc-editor-title');
  const editorParent = document.getElementById('doc-editor-parent');
  const editorCategory = document.getElementById('doc-editor-category');
  const editorTags = document.getElementById('doc-editor-tags');
  const editorContent = document.getElementById('doc-editor-content');
  const deleteButton = document.getElementById('doc-delete-button');

  let selectedId = null;

  function filteredDocIds() {
    const selectedCategory = filterCategory.value;
    const selectedTag = filterTag.value.trim().toLowerCase();

    if (!selectedCategory && !selectedTag) {
      return new Set(state.documents.map((doc) => doc.id));
    }

    const map = new Map(state.documents.map((doc) => [doc.id, doc]));
    const ids = new Set();

    for (const doc of state.documents) {
      const categoryPass = !selectedCategory || doc.category === selectedCategory;
      const tagPass = !selectedTag || doc.tags.some((tag) => tag.toLowerCase().includes(selectedTag));
      if (!categoryPass || !tagPass) continue;

      ids.add(doc.id);

      let cursor = doc;
      while (cursor.parentId) {
        const parent = map.get(cursor.parentId);
        if (!parent) break;
        ids.add(parent.id);
        cursor = parent;
      }
    }

    return ids;
  }

  function renderParentSelect(selectElement, options, current = '') {
    selectElement.innerHTML = '';

    const root = document.createElement('option');
    root.value = '';
    root.textContent = '(No parent)';
    selectElement.append(root);

    for (const doc of options) {
      const option = document.createElement('option');
      option.value = doc.id;
      option.textContent = doc.title;
      option.selected = current === doc.id;
      selectElement.append(option);
    }
  }

  function renderCreateParentOptions() {
    const options = [...state.documents].sort(byTitle);
    renderParentSelect(createParent, options);
  }

  function renderEditorParentOptions(document) {
    if (!document) {
      renderParentSelect(editorParent, []);
      return;
    }

    const blocked = collectDescendants(state.documents, document.id);
    blocked.add(document.id);

    const options = state.documents
      .filter((doc) => !blocked.has(doc.id))
      .sort(byTitle);

    renderParentSelect(editorParent, options, document.parentId || '');
  }

  function renderFilterOptions() {
    const current = filterCategory.value;
    const categories = [...new Set(state.documents.map((doc) => doc.category).filter(Boolean))].sort();

    filterCategory.innerHTML = '';

    const all = document.createElement('option');
    all.value = '';
    all.textContent = 'All categories';
    filterCategory.append(all);

    for (const category of categories) {
      const option = document.createElement('option');
      option.value = category;
      option.textContent = category;
      filterCategory.append(option);
    }

    filterCategory.value = categories.includes(current) ? current : '';
  }

  function renderTree() {
    tree.innerHTML = '';

    const visibleIds = filteredDocIds();
    const childrenMap = buildChildrenMap(state.documents);

    function appendBranch(parentId, container) {
      const children = childrenMap.get(parentId || null) || [];
      for (const doc of children) {
        if (!visibleIds.has(doc.id)) continue;

        const item = document.createElement('li');
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'doc-node';
        button.dataset.docId = doc.id;
        button.textContent = `${doc.title} (${doc.category})`;

        if (doc.id === selectedId) {
          button.classList.add('active');
        }

        item.append(button);

        const childContainer = document.createElement('ul');
        appendBranch(doc.id, childContainer);

        if (childContainer.childElementCount > 0) {
          item.append(childContainer);
        }

        container.append(item);
      }
    }

    appendBranch(null, tree);

    if (tree.childElementCount === 0) {
      const hint = document.createElement('p');
      hint.className = 'doc-hint';
      hint.textContent = 'No pages match your current filters.';
      tree.append(hint);
    }
  }

  function setEditorEnabled(enabled) {
    for (const field of [editorTitle, editorParent, editorCategory, editorTags, editorContent]) {
      field.disabled = !enabled;
    }
    deleteButton.disabled = !enabled;
  }

  function renderEditor() {
    const document = state.documents.find((doc) => doc.id === selectedId) || null;

    if (!document) {
      editorId.value = '';
      editorTitle.value = '';
      editorCategory.value = '';
      editorTags.value = '';
      editorContent.value = '';
      renderEditorParentOptions(null);
      setEditorEnabled(false);
      return;
    }

    setEditorEnabled(true);
    editorId.value = document.id;
    editorTitle.value = document.title;
    editorCategory.value = document.category;
    editorTags.value = document.tags.join(', ');
    editorContent.value = document.content;
    renderEditorParentOptions(document);
  }

  async function handleCreate(event) {
    event.preventDefault();

    const payload = {
      title: createTitle.value.trim(),
      parentId: createParent.value || null,
      category: createCategory.value.trim() || 'General',
      tags: parseTags(createTags.value),
      content: '',
    };

    if (!payload.title) {
      setMessage('Page title is required.', true);
      return;
    }

    try {
      const result = await api.createDocument(payload);
      applyServerResult(result);
      selectedId = result.document?.id || selectedId;
      createForm.reset();
      render();
      setMessage('Page created.');
    } catch (error) {
      setMessage(error.message, true);
    }
  }

  async function handleEditorSave(event) {
    event.preventDefault();

    if (!editorId.value) {
      setMessage('Select a page before saving.', true);
      return;
    }

    const payload = {
      title: editorTitle.value.trim(),
      parentId: editorParent.value || null,
      category: editorCategory.value.trim() || 'General',
      tags: parseTags(editorTags.value),
      content: editorContent.value,
    };

    if (!payload.title) {
      setMessage('Page title is required.', true);
      return;
    }

    try {
      const result = await api.updateDocument(editorId.value, payload);
      applyServerResult(result);
      selectedId = result.document?.id || selectedId;
      render();
      setMessage('Page saved.');
    } catch (error) {
      setMessage(error.message, true);
    }
  }

  async function handleDelete() {
    if (!editorId.value) return;

    if (!window.confirm('Delete this page and all nested child pages?')) return;

    try {
      const result = await api.deleteDocument(editorId.value);
      applyServerResult(result);
      selectedId = null;
      render();
      setMessage('Page deleted.');
    } catch (error) {
      setMessage(error.message, true);
    }
  }

  function handleTreeClick(event) {
    const button = event.target.closest('button[data-doc-id]');
    if (!button) return;

    selectedId = button.dataset.docId;
    render();
  }

  function init() {
    createForm.addEventListener('submit', handleCreate);
    tree.addEventListener('click', handleTreeClick);
    editorForm.addEventListener('submit', handleEditorSave);
    deleteButton.addEventListener('click', handleDelete);

    filterCategory.addEventListener('change', () => render());
    filterTag.addEventListener('input', () => render());
  }

  function render() {
    if (selectedId && !state.documents.some((doc) => doc.id === selectedId)) {
      selectedId = null;
    }

    renderCreateParentOptions();
    renderFilterOptions();
    renderTree();
    renderEditor();
  }

  return { init, render };
}
