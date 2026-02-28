async function request(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: {
      'content-type': 'application/json',
      ...(options.headers || {}),
    },
  });

  const text = await response.text();
  const payload = text ? JSON.parse(text) : {};

  if (!response.ok) {
    throw new Error(payload.error || `Request failed (${response.status}).`);
  }

  return payload;
}

export const api = {
  getState() {
    return request('/api/state', { method: 'GET' });
  },
  createTask(task) {
    return request('/api/tasks', {
      method: 'POST',
      body: JSON.stringify(task),
    });
  },
  updateTask(taskId, updates) {
    return request(`/api/tasks/${encodeURIComponent(taskId)}`, {
      method: 'PATCH',
      body: JSON.stringify(updates),
    });
  },
  deleteTask(taskId) {
    return request(`/api/tasks/${encodeURIComponent(taskId)}`, {
      method: 'DELETE',
    });
  },
  createDocument(document) {
    return request('/api/documents', {
      method: 'POST',
      body: JSON.stringify(document),
    });
  },
  updateDocument(documentId, updates) {
    return request(`/api/documents/${encodeURIComponent(documentId)}`, {
      method: 'PATCH',
      body: JSON.stringify(updates),
    });
  },
  deleteDocument(documentId) {
    return request(`/api/documents/${encodeURIComponent(documentId)}`, {
      method: 'DELETE',
    });
  },
};
