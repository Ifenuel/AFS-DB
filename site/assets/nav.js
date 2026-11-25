/* Grouped navigation behaviour: click or hover to open, Escape and outside
   clicks close, focus stays predictable for keyboard and screen-reader users. */
(function () {
  var groups = Array.prototype.slice.call(document.querySelectorAll('.nav-group'));
  if (!groups.length) return;

  var hoverable = window.matchMedia('(hover: hover) and (pointer: fine)').matches;
  var closeTimer = null;

  // A 180ms grace period: moving from the trigger into the panel (or briefly
  // off it) must not close the menu before the first item is reachable.
  function cancelClose() {
    if (closeTimer) { clearTimeout(closeTimer); closeTimer = null; }
  }

  function scheduleClose(group) {
    cancelClose();
    closeTimer = setTimeout(function () { close(group, false); }, 180);
  }

  function close(group, restoreFocus) {
    if (group.getAttribute('data-open') !== 'true') return;
    cancelClose();
    group.setAttribute('data-open', 'false');
    var trigger = group.querySelector('.nav-trigger');
    trigger.setAttribute('aria-expanded', 'false');
    if (restoreFocus) trigger.focus();
  }

  function closeAll(except) {
    groups.forEach(function (g) { if (g !== except) close(g, false); });
  }

  function open(group) {
    cancelClose();
    closeAll(group);
    var trigger = group.querySelector('.nav-trigger');
    var panel = group.querySelector('.nav-panel');

    group.setAttribute('data-open', 'true');
    trigger.setAttribute('aria-expanded', 'true');

    // Keep the panel inside the viewport; measured after it is laid out.
    group.removeAttribute('data-align');
    var triggerRect = trigger.getBoundingClientRect();
    if (triggerRect.left + panel.offsetWidth > window.innerWidth - 16) {
      group.setAttribute('data-align', 'right');
    }
  }

  groups.forEach(function (group) {
    var trigger = group.querySelector('.nav-trigger');
    var panel = group.querySelector('.nav-panel');

    // Click always opens. Pointer devices may already have opened it on hover, so a
    // toggle here would close the panel the moment it is clicked.
    trigger.addEventListener('click', function (event) {
      event.preventDefault();
      // A click toggles a menu that a click opened; it never closes a menu the
      // pointer just opened, which would feel like the menu rejecting the click.
      if (group.getAttribute('data-open') === 'true' && group.getAttribute('data-opened-by') === 'click') {
        close(group, true);
        return;
      }
      group.setAttribute('data-opened-by', 'click');
      open(group);
    });

    if (hoverable) {
      group.addEventListener('pointerenter', function () {
        cancelClose();
        if (group.getAttribute('data-open') !== 'true') group.setAttribute('data-opened-by', 'hover');
        open(group);
      });
      group.addEventListener('pointerleave', function () { scheduleClose(group); });
      // Entering the panel itself always cancels a pending close, even if the
      // event target is a child of the panel.
      panel.addEventListener('pointerenter', cancelClose);
      panel.addEventListener('pointermove', cancelClose);
    }

    panel.addEventListener('keydown', function (event) {
      var items = Array.prototype.slice.call(panel.querySelectorAll('.nav-item'));
      var index = items.indexOf(document.activeElement);
      if (event.key === 'ArrowDown') {
        event.preventDefault();
        (items[index + 1] || items[0]).focus();
      } else if (event.key === 'ArrowUp') {
        event.preventDefault();
        (items[index - 1] || items[items.length - 1]).focus();
      } else if (event.key === 'Escape') {
        event.preventDefault();
        close(group, true);
      }
    });
  });

  document.addEventListener('keydown', function (event) {
    if (event.key === 'Escape') return;
    triggerFocus(event);
  });

  function triggerFocus(event) {
    if (!['Enter', ' '].includes(event.key)) return;
    var trigger = document.activeElement;
    if (trigger && trigger.classList.contains('nav-trigger')) {
      event.preventDefault();
      open(trigger.closest('.nav-group'));
    }
  }

  document.addEventListener('keydown', function (event) {
    if (event.key !== 'Escape') return;
    groups.forEach(function (group) {
      if (group.getAttribute('data-open') === 'true') close(group, true);
    });
  });

  document.addEventListener('click', function (event) {
    if (!event.target.closest('.nav-group')) closeAll(null);
  });

  document.addEventListener('focusin', function (event) {
    if (!event.target.closest('.nav-group')) closeAll(null);
  });
})();
