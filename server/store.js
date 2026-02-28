const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const DATA_DIR = path.resolve(__dirname, '..', 'data');
const DATA_FILE = path.join(DATA_DIR, 'app-data.json');
const TASK_STATUSES = ['proposed', 'in_progress', 'review', 'finished'];

const EMPTY_STATE = {
  tasks: [],
  projects: ['Inbox'],
  people: [],
  documents: [
    {
      id: 'doc_root',
      parentId: null,
      title: 'Workspace Home',
      category: 'General',
      tags: ['welcome'],
      content:
        'This is your local-first knowledge space. Add nested pages, categories, and tags.',
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    },
  ],
};

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function nowIso() {
  return new Date().toISOString();
}

function createId(prefix) {
  return `${prefix}_${crypto.randomUUID()}`;
}

function normalizeText(value, fallback = '') {
  if (typeof value !== 'string') return fallback;
  const trimmed = value.trim();
  return trimmed || fallback;
}

function normalizeTags(value) {
  const source = Array.isArray(value) ? value : String(value || '').split(',');
  return [...new Set(source.map((tag) => String(tag).trim()).filter(Boolean))];
}

function normalizeAssignees(value) {
  const source = Array.isArray(value) ? value : String(value || '').split(',');
  return [...new Set(source.map((name) => String(name).trim()).filter(Boolean))];
}

function ensureStoreFile() {
  fs.mkdirSync(DATA_DIR, { recursive: true });

  if (!fs.existsSync(DATA_FILE)) {
    fs.writeFileSync(DATA_FILE, JSON.stringify(EMPTY_STATE, null, 2), 'utf8');
    return clone(EMPTY_STATE);
  }

  const raw = fs.readFileSync(DATA_FILE, 'utf8');
  if (!raw.trim()) {
    fs.writeFileSync(DATA_FILE, JSON.stringify(EMPTY_STATE, null, 2), 'utf8');
    return clone(EMPTY_STATE);
  }

  try {
    const parsed = JSON.parse(raw);
    return {
      tasks: Array.isArray(parsed.tasks) ? parsed.tasks : [],
      projects: Array.isArray(parsed.projects) ? parsed.projects : ['Inbox'],
      people: Array.isArray(parsed.people) ? parsed.people : [],
      documents: Array.isArray(parsed.documents) ? parsed.documents : clone(EMPTY_STATE.documents),
    };
  } catch {
    fs.writeFileSync(DATA_FILE, JSON.stringify(EMPTY_STATE, null, 2), 'utf8');
    return clone(EMPTY_STATE);
  }
}

let store = ensureStoreFile();

function persist() {
  fs.writeFileSync(DATA_FILE, JSON.stringify(store, null, 2), 'utf8');
}

function syncPeopleAndProjects() {
  const people = new Set(store.people);
  const projects = new Set(store.projects);

  for (const task of store.tasks) {
    projects.add(task.project || 'Inbox');
    for (const assignee of task.assignees || []) {
      people.add(assignee);
    }
  }

  store.people = [...people].sort((a, b) => a.localeCompare(b));
  store.projects = [...projects].sort((a, b) => a.localeCompare(b));
}

function getState() {
  return clone(store);
}

function createTask(payload) {
  const title = normalizeText(payload.title);
  if (!title) {
    const error = new Error('Task title is required.');
    error.statusCode = 400;
    throw error;
  }

  const task = {
    id: createId('task'),
    title,
    dueDate: normalizeText(payload.dueDate, ''),
    project: normalizeText(payload.project, 'Inbox'),
    assignees: normalizeAssignees(payload.assignees),
    status: TASK_STATUSES.includes(payload.status) ? payload.status : 'proposed',
    createdAt: nowIso(),
    updatedAt: nowIso(),
  };

  store.tasks.unshift(task);
  syncPeopleAndProjects();
  persist();

  return { state: getState(), task: clone(task) };
}

function updateTask(taskId, payload) {
  const task = store.tasks.find((item) => item.id === taskId);
  if (!task) {
    const error = new Error('Task not found.');
    error.statusCode = 404;
    throw error;
  }

  if (payload.title !== undefined) {
    const title = normalizeText(payload.title);
    if (!title) {
      const error = new Error('Task title is required.');
      error.statusCode = 400;
      throw error;
    }
    task.title = title;
  }

  if (payload.dueDate !== undefined) task.dueDate = normalizeText(payload.dueDate, '');
  if (payload.project !== undefined) task.project = normalizeText(payload.project, 'Inbox');
  if (payload.assignees !== undefined) task.assignees = normalizeAssignees(payload.assignees);
  if (payload.status !== undefined && TASK_STATUSES.includes(payload.status)) task.status = payload.status;

  task.updatedAt = nowIso();
  syncPeopleAndProjects();
  persist();

  return { state: getState(), task: clone(task) };
}

function deleteTask(taskId) {
  const before = store.tasks.length;
  store.tasks = store.tasks.filter((item) => item.id !== taskId);

  if (store.tasks.length === before) {
    const error = new Error('Task not found.');
    error.statusCode = 404;
    throw error;
  }

  syncPeopleAndProjects();
  persist();
  return { state: getState() };
}

function createDocument(payload) {
  const title = normalizeText(payload.title);
  if (!title) {
    const error = new Error('Page title is required.');
    error.statusCode = 400;
    throw error;
  }

  let parentId = payload.parentId || null;
  if (parentId && !store.documents.some((doc) => doc.id === parentId)) {
    parentId = null;
  }

  const document = {
    id: createId('doc'),
    parentId,
    title,
    category: normalizeText(payload.category, 'General'),
    tags: normalizeTags(payload.tags),
    content: typeof payload.content === 'string' ? payload.content : '',
    createdAt: nowIso(),
    updatedAt: nowIso(),
  };

  store.documents.push(document);
  persist();

  return { state: getState(), document: clone(document) };
}

function collectDescendantIds(documentId, result = new Set()) {
  for (const doc of store.documents) {
    if (doc.parentId === documentId) {
      result.add(doc.id);
      collectDescendantIds(doc.id, result);
    }
  }
  return result;
}

function updateDocument(documentId, payload) {
  const document = store.documents.find((item) => item.id === documentId);
  if (!document) {
    const error = new Error('Document not found.');
    error.statusCode = 404;
    throw error;
  }

  if (payload.title !== undefined) {
    const title = normalizeText(payload.title);
    if (!title) {
      const error = new Error('Page title is required.');
      error.statusCode = 400;
      throw error;
    }
    document.title = title;
  }

  if (payload.category !== undefined) {
    document.category = normalizeText(payload.category, 'General');
  }

  if (payload.tags !== undefined) {
    document.tags = normalizeTags(payload.tags);
  }

  if (payload.content !== undefined) {
    document.content = typeof payload.content === 'string' ? payload.content : '';
  }

  if (payload.parentId !== undefined) {
    const nextParentId = payload.parentId || null;
    if (nextParentId && !store.documents.some((doc) => doc.id === nextParentId)) {
      const error = new Error('Parent page does not exist.');
      error.statusCode = 400;
      throw error;
    }

    const descendants = collectDescendantIds(document.id);
    if (nextParentId === document.id || descendants.has(nextParentId)) {
      const error = new Error('Invalid parent page.');
      error.statusCode = 400;
      throw error;
    }

    document.parentId = nextParentId;
  }

  document.updatedAt = nowIso();
  persist();

  return { state: getState(), document: clone(document) };
}

function deleteDocument(documentId) {
  const descendants = collectDescendantIds(documentId);
  descendants.add(documentId);

  const before = store.documents.length;
  store.documents = store.documents.filter((doc) => !descendants.has(doc.id));

  if (store.documents.length === before) {
    const error = new Error('Document not found.');
    error.statusCode = 404;
    throw error;
  }

  persist();
  return { state: getState() };
}

module.exports = {
  TASK_STATUSES,
  createDocument,
  createTask,
  deleteDocument,
  deleteTask,
  getState,
  updateDocument,
  updateTask,
};
