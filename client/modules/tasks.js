const STATUS_ORDER = ['proposed', 'in_progress', 'review', 'finished'];
const STATUS_LABELS = {
  proposed: 'Proposed',
  in_progress: 'In progress',
  review: 'Review',
  finished: 'Finished',
};

function parseAssignees(raw) {
  return [...new Set(String(raw || '').split(',').map((item) => item.trim()).filter(Boolean))];
}

function formatDate(value) {
  if (!value) return 'No date';
  const date = new Date(`${value}T00:00:00`);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleDateString();
}

function taskSort(a, b) {
  const left = a.dueDate || '9999-12-31';
  const right = b.dueDate || '9999-12-31';
  if (left !== right) return left.localeCompare(right);
  return b.updatedAt.localeCompare(a.updatedAt);
}

export function createTaskModule({ state, api, applyServerResult, setMessage }) {
  const form = document.getElementById('task-form');
  const titleInput = document.getElementById('task-title');
  const dueDateInput = document.getElementById('task-due-date');
  const projectInput = document.getElementById('task-project');
  const assigneeInput = document.getElementById('task-assignees');
  const peopleOptions = document.getElementById('people-options');
  const projectOptions = document.getElementById('project-options');
  const rows = document.getElementById('task-rows');
  const board = document.getElementById('kanban-board');

  let draggingTaskId = null;

  function renderDatalists() {
    peopleOptions.innerHTML = '';
    for (const person of state.people) {
      const option = document.createElement('option');
      option.value = person;
      peopleOptions.append(option);
    }

    projectOptions.innerHTML = '';
    for (const project of state.projects) {
      const option = document.createElement('option');
      option.value = project;
      projectOptions.append(option);
    }
  }

  function renderRows() {
    rows.innerHTML = '';

    const sorted = [...state.tasks].sort(taskSort);
    for (const task of sorted) {
      const row = document.createElement('tr');

      const titleCell = document.createElement('td');
      titleCell.textContent = task.title;

      const projectCell = document.createElement('td');
      projectCell.textContent = task.project || 'Inbox';

      const dueCell = document.createElement('td');
      dueCell.textContent = formatDate(task.dueDate);

      const assigneeCell = document.createElement('td');
      assigneeCell.textContent = task.assignees.length ? task.assignees.join(', ') : 'Unassigned';

      const statusCell = document.createElement('td');
      const statusSelect = document.createElement('select');
      statusSelect.dataset.taskId = task.id;
      statusSelect.dataset.kind = 'status-select';
      for (const status of STATUS_ORDER) {
        const option = document.createElement('option');
        option.value = status;
        option.textContent = STATUS_LABELS[status];
        option.selected = task.status === status;
        statusSelect.append(option);
      }
      statusCell.append(statusSelect);

      const actionCell = document.createElement('td');
      const deleteButton = document.createElement('button');
      deleteButton.type = 'button';
      deleteButton.className = 'button danger';
      deleteButton.dataset.kind = 'delete-task';
      deleteButton.dataset.taskId = task.id;
      deleteButton.textContent = 'Delete';
      actionCell.append(deleteButton);

      row.append(titleCell, projectCell, dueCell, assigneeCell, statusCell, actionCell);
      rows.append(row);
    }
  }

  function createTaskCard(task) {
    const card = document.createElement('article');
    card.className = 'task-card';
    card.draggable = true;
    card.dataset.taskId = task.id;

    const title = document.createElement('strong');
    title.textContent = task.title;

    const project = document.createElement('div');
    project.className = 'task-meta';
    project.textContent = `Project: ${task.project || 'Inbox'}`;

    const people = document.createElement('div');
    people.className = 'task-meta';
    people.textContent = `People: ${task.assignees.length ? task.assignees.join(', ') : 'None'}`;

    const due = document.createElement('div');
    due.className = 'task-meta';
    due.textContent = `Due: ${formatDate(task.dueDate)}`;

    card.append(title, project, people, due);
    return card;
  }

  function renderBoard() {
    for (const status of STATUS_ORDER) {
      const lane = board.querySelector(`.kanban-dropzone[data-status="${status}"]`);
      lane.innerHTML = '';

      const laneTasks = state.tasks.filter((task) => task.status === status).sort(taskSort);
      for (const task of laneTasks) {
        lane.append(createTaskCard(task));
      }
    }
  }

  async function updateTaskStatus(taskId, status) {
    try {
      const result = await api.updateTask(taskId, { status });
      applyServerResult(result);
      setMessage('Task updated.');
    } catch (error) {
      setMessage(error.message, true);
    }
  }

  async function handleSubmit(event) {
    event.preventDefault();

    const payload = {
      title: titleInput.value.trim(),
      dueDate: dueDateInput.value,
      project: projectInput.value.trim() || 'Inbox',
      assignees: parseAssignees(assigneeInput.value),
      status: 'proposed',
    };

    if (!payload.title) {
      setMessage('Task title is required.', true);
      return;
    }

    try {
      const result = await api.createTask(payload);
      applyServerResult(result);
      form.reset();
      setMessage('Task added.');
    } catch (error) {
      setMessage(error.message, true);
    }
  }

  async function handleTableChange(event) {
    const select = event.target.closest('select[data-kind="status-select"]');
    if (!select) return;

    await updateTaskStatus(select.dataset.taskId, select.value);
  }

  async function handleTableClick(event) {
    const button = event.target.closest('button[data-kind="delete-task"]');
    if (!button) return;

    if (!window.confirm('Delete this task?')) return;

    try {
      const result = await api.deleteTask(button.dataset.taskId);
      applyServerResult(result);
      setMessage('Task deleted.');
    } catch (error) {
      setMessage(error.message, true);
    }
  }

  function handleBoardDragStart(event) {
    const card = event.target.closest('.task-card');
    if (!card) return;

    draggingTaskId = card.dataset.taskId;
    event.dataTransfer.effectAllowed = 'move';
    event.dataTransfer.setData('text/plain', draggingTaskId);
  }

  function handleBoardDragOver(event) {
    const zone = event.target.closest('.kanban-dropzone');
    if (!zone) return;

    event.preventDefault();
    zone.classList.add('is-over');
  }

  function handleBoardDragLeave(event) {
    const zone = event.target.closest('.kanban-dropzone');
    if (!zone) return;

    zone.classList.remove('is-over');
  }

  async function handleBoardDrop(event) {
    const zone = event.target.closest('.kanban-dropzone');
    if (!zone) return;

    event.preventDefault();
    zone.classList.remove('is-over');

    const droppedId = event.dataTransfer.getData('text/plain') || draggingTaskId;
    if (!droppedId) return;

    await updateTaskStatus(droppedId, zone.dataset.status);
    draggingTaskId = null;
  }

  function init() {
    form.addEventListener('submit', handleSubmit);
    rows.addEventListener('change', handleTableChange);
    rows.addEventListener('click', handleTableClick);

    board.addEventListener('dragstart', handleBoardDragStart);
    board.addEventListener('dragover', handleBoardDragOver);
    board.addEventListener('dragleave', handleBoardDragLeave);
    board.addEventListener('drop', handleBoardDrop);
    board.addEventListener('dragend', () => {
      draggingTaskId = null;
      board.querySelectorAll('.kanban-dropzone').forEach((zone) => zone.classList.remove('is-over'));
    });
  }

  function render() {
    renderDatalists();
    renderRows();
    renderBoard();
  }

  return { init, render };
}
