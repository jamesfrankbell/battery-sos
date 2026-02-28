import { api } from './modules/api.js';
import { createDocumentsModule } from './modules/documents.js';
import { createTaskModule } from './modules/tasks.js';

const syncStatus = document.getElementById('sync-status');
const message = document.getElementById('app-message');

const state = {
  tasks: [],
  projects: [],
  people: [],
  documents: [],
};

function setMessage(text, isError = false) {
  message.textContent = text;
  message.classList.toggle('error', isError);
}

function setSyncStatus() {
  syncStatus.textContent = `${state.tasks.length} tasks | ${state.documents.length} pages`;
}

let tasksModule;
let documentsModule;

function applyState(nextState) {
  state.tasks = Array.isArray(nextState.tasks) ? nextState.tasks : [];
  state.projects = Array.isArray(nextState.projects) ? nextState.projects : [];
  state.people = Array.isArray(nextState.people) ? nextState.people : [];
  state.documents = Array.isArray(nextState.documents) ? nextState.documents : [];

  tasksModule.render();
  documentsModule.render();
  setSyncStatus();
}

function applyServerResult(result) {
  const nextState = result && result.state ? result.state : result;
  applyState(nextState);
}

async function boot() {
  tasksModule = createTaskModule({ state, api, applyServerResult, setMessage });
  documentsModule = createDocumentsModule({ state, api, applyServerResult, setMessage });

  tasksModule.init();
  documentsModule.init();

  try {
    const initialState = await api.getState();
    applyState(initialState);
    setMessage('Ready. Data is stored locally on this machine.');
  } catch (error) {
    setMessage(error.message, true);
  }
}

boot();
