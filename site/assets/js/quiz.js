(function () {
  'use strict';

  var config = window.__QUIZ_CONFIG || {};
  if (!config.pageId) {
    return;
  }

  var content = document.querySelector('article.doc .content');
  if (!content) {
    return;
  }

  function normalize(value) {
    return String(value || '').trim().toLowerCase();
  }

  function findNextList(heading) {
    var node = heading.nextElementSibling;
    while (node) {
      if (node.tagName === 'OL' || node.tagName === 'UL') {
        return node;
      }
      if (/^H[1-6]$/.test(node.tagName)) {
        break;
      }
      node = node.nextElementSibling;
    }
    return null;
  }

  function stripLeadingIndex(value) {
    return String(value || '').replace(/^\s*\d+[\)\.\:]\s*/, '').trim();
  }

  function parseOption(text, index) {
    var clean = stripLeadingIndex(text);
    var match = clean.match(/^([A-Z])[\)\.\:]\s*(.+)$/i);
    if (match) {
      return { label: match[1].toUpperCase(), text: match[2].trim() };
    }

    var label = String.fromCharCode(65 + index);
    return { label: label, text: clean };
  }

  function parseExpectedOption(answerText) {
    var match = String(answerText || '').trim().match(/^([A-Z])(?:[\)\.\:]?)$/i);
    if (!match) {
      return '';
    }
    return match[1].toUpperCase();
  }

  function extractQuestion(li, index) {
    var options = [];
    var promptChunks = [];
    var children = Array.prototype.slice.call(li.childNodes);

    children.forEach(function (child) {
      if (child.nodeType === Node.TEXT_NODE) {
        var text = child.textContent.trim();
        if (text) {
          promptChunks.push(text);
        }
        return;
      }

      if (child.nodeType !== Node.ELEMENT_NODE) {
        return;
      }

      var tag = child.tagName;
      if (tag === 'UL' || tag === 'OL') {
        var optionItems = child.querySelectorAll(':scope > li');
        optionItems.forEach(function (opt, optionIndex) {
          options.push(parseOption(opt.textContent, optionIndex));
        });
        return;
      }

      if (tag === 'P' || tag === 'DIV' || tag === 'SPAN') {
        var chunk = child.textContent.trim();
        if (chunk) {
          promptChunks.push(chunk);
        }
      }
    });

    var prompt = stripLeadingIndex(promptChunks.join(' ').trim());
    if (!prompt) {
      prompt = stripLeadingIndex(li.textContent.trim());
    }

    return {
      id: 'q' + (index + 1),
      index: index + 1,
      prompt: prompt,
      options: options,
    };
  }

  function extractQuestions(list) {
    var items = Array.prototype.slice.call(list.querySelectorAll(':scope > li'));
    return items.map(extractQuestion);
  }

  function extractAnswers(list) {
    var items = Array.prototype.slice.call(list.querySelectorAll(':scope > li'));
    return items.map(function (li) {
      return stripLeadingIndex(li.textContent.trim());
    });
  }

  function createField(question) {
    var wrapper = document.createElement('div');
    wrapper.className = 'quiz-question';
    wrapper.dataset.questionId = question.id;

    var title = document.createElement('h3');
    title.textContent = question.index + '. ' + question.prompt;
    wrapper.appendChild(title);

    var body = document.createElement('div');
    body.className = 'quiz-answer';

    if (question.options.length > 1) {
      question.options.forEach(function (option) {
        var label = document.createElement('label');
        label.className = 'quiz-option';

        var input = document.createElement('input');
        input.type = 'radio';
        input.name = question.id;
        input.value = option.label;

        var text = document.createElement('span');
        text.textContent = option.label + ') ' + option.text;

        label.appendChild(input);
        label.appendChild(text);
        body.appendChild(label);
      });
    } else {
      var textarea = document.createElement('textarea');
      textarea.name = question.id;
      textarea.rows = 3;
      textarea.placeholder = 'Write your answer...';
      body.appendChild(textarea);
    }

    var hint = document.createElement('p');
    hint.className = 'quiz-hint';
    hint.textContent = question.options.length > 1
      ? 'Objective question (auto-checked).'
      : 'Open-ended question (manual self-check).';

    wrapper.appendChild(body);
    wrapper.appendChild(hint);

    return wrapper;
  }

  function collectResponses(questions, root) {
    var responses = {};

    questions.forEach(function (question) {
      if (question.options.length > 1) {
        var selected = root.querySelector('input[name="' + question.id + '"]:checked');
        responses[question.id] = selected ? selected.value : '';
      } else {
        var textarea = root.querySelector('textarea[name="' + question.id + '"]');
        responses[question.id] = textarea ? textarea.value.trim() : '';
      }
    });

    return responses;
  }

  function restoreResponses(questions, root, responses) {
    if (!responses) {
      return;
    }

    questions.forEach(function (question) {
      var value = responses[question.id] || '';
      if (!value) {
        return;
      }

      if (question.options.length > 1) {
        var target = root.querySelector('input[name="' + question.id + '"][value="' + value + '"]');
        if (target) {
          target.checked = true;
        }
      } else {
        var textarea = root.querySelector('textarea[name="' + question.id + '"]');
        if (textarea) {
          textarea.value = value;
        }
      }
    });
  }

  var headings = Array.prototype.slice.call(content.querySelectorAll('h2'));
  var questionsHeading = headings.find(function (h) {
    return normalize(h.textContent).indexOf('questions') === 0;
  });
  var answersHeading = headings.find(function (h) {
    return normalize(h.textContent).indexOf('answer key') === 0;
  });

  if (!questionsHeading || !answersHeading) {
    return;
  }

  var questionsList = findNextList(questionsHeading);
  var answersList = findNextList(answersHeading);
  if (!questionsList || !answersList) {
    return;
  }

  var questions = extractQuestions(questionsList);
  var answers = extractAnswers(answersList);
  if (!questions.length || !answers.length) {
    return;
  }

  var storageKey = 'safeops.quiz.' + config.pageId;
  var saved = null;
  try {
    saved = JSON.parse(localStorage.getItem(storageKey) || 'null');
  } catch (error) {
    saved = null;
  }

  var section = document.createElement('section');
  section.className = 'quiz-tool';

  var heading = document.createElement('h2');
  heading.textContent = 'Interactive Quiz (Local Mode)';
  section.appendChild(heading);

  var summary = document.createElement('p');
  summary.className = 'quiz-summary';
  summary.textContent = 'Answers are saved in your browser. Objective questions are auto-checked; open-ended answers are self-review.';
  section.appendChild(summary);

  var fields = document.createElement('div');
  fields.className = 'quiz-fields';
  questions.forEach(function (question) {
    fields.appendChild(createField(question));
  });
  section.appendChild(fields);

  var actions = document.createElement('div');
  actions.className = 'quiz-actions';

  var saveButton = document.createElement('button');
  saveButton.type = 'button';
  saveButton.className = 'button quiz-button';
  saveButton.textContent = 'Save Progress';

  var checkButton = document.createElement('button');
  checkButton.type = 'button';
  checkButton.className = 'button quiz-button primary';
  checkButton.textContent = 'Check Answers';

  var resetButton = document.createElement('button');
  resetButton.type = 'button';
  resetButton.className = 'button quiz-button danger';
  resetButton.textContent = 'Reset';

  actions.appendChild(saveButton);
  actions.appendChild(checkButton);
  actions.appendChild(resetButton);
  section.appendChild(actions);

  var status = document.createElement('p');
  status.className = 'quiz-status';
  section.appendChild(status);

  var answerToggle = document.createElement('details');
  answerToggle.className = 'quiz-answer-key';
  var answerSummary = document.createElement('summary');
  answerSummary.textContent = 'Show answer key';
  answerToggle.appendChild(answerSummary);

  var answerList = document.createElement('ol');
  answers.forEach(function (answer) {
    var li = document.createElement('li');
    li.textContent = answer;
    answerList.appendChild(li);
  });
  answerToggle.appendChild(answerList);
  section.appendChild(answerToggle);

  questionsHeading.parentNode.insertBefore(section, questionsHeading);

  answersHeading.style.display = 'none';
  answersList.style.display = 'none';

  var hiddenNode = answersList.nextElementSibling;
  while (hiddenNode && !/^H[1-6]$/.test(hiddenNode.tagName)) {
    hiddenNode.style.display = 'none';
    hiddenNode = hiddenNode.nextElementSibling;
  }

  if (saved && saved.responses) {
    restoreResponses(questions, section, saved.responses);
    status.textContent = saved.checkedAt
      ? 'Loaded saved answers from ' + new Date(saved.checkedAt).toLocaleString() + '.'
      : 'Loaded saved answers.';
  }

  function persist(responses, score) {
    var payload = {
      pageId: config.pageId,
      responses: responses,
      score: score || null,
      checkedAt: new Date().toISOString(),
    };

    localStorage.setItem(storageKey, JSON.stringify(payload));

    if (!config.apiEndpoint) {
      return;
    }

    fetch(config.apiEndpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(payload),
    }).catch(function (error) {
      console.warn('[quiz] failed to sync result:', error);
    });
  }

  saveButton.addEventListener('click', function () {
    var responses = collectResponses(questions, section);
    persist(responses, null);
    status.textContent = 'Progress saved locally.';
  });

  checkButton.addEventListener('click', function () {
    var responses = collectResponses(questions, section);
    var objectiveTotal = 0;
    var objectiveCorrect = 0;

    questions.forEach(function (question, idx) {
      var expected = parseExpectedOption(answers[idx] || '');
      var container = section.querySelector('[data-question-id="' + question.id + '"]');
      container.classList.remove('is-correct', 'is-incorrect');

      if (question.options.length > 1 && expected) {
        objectiveTotal += 1;
        if ((responses[question.id] || '').toUpperCase() === expected) {
          objectiveCorrect += 1;
          container.classList.add('is-correct');
        } else {
          container.classList.add('is-incorrect');
        }
      }
    });

    var score = {
      correct: objectiveCorrect,
      total: objectiveTotal,
    };

    persist(responses, score);
    answerToggle.open = true;

    if (objectiveTotal > 0) {
      status.textContent = 'Objective score: ' + objectiveCorrect + '/' + objectiveTotal + '. Open-ended answers require manual self-check.';
    } else {
      status.textContent = 'Answers saved. Use the answer key for manual self-check.';
    }
  });

  resetButton.addEventListener('click', function () {
    localStorage.removeItem(storageKey);
    questions.forEach(function (question) {
      var radios = section.querySelectorAll('input[name="' + question.id + '"]');
      radios.forEach(function (radio) {
        radio.checked = false;
      });
      var textarea = section.querySelector('textarea[name="' + question.id + '"]');
      if (textarea) {
        textarea.value = '';
      }
      var container = section.querySelector('[data-question-id="' + question.id + '"]');
      container.classList.remove('is-correct', 'is-incorrect');
    });
    answerToggle.open = false;
    status.textContent = 'Progress cleared.';
  });
})();
