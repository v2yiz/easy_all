(function () {
  "use strict";

  var toggle = document.querySelector(".nav-toggle");
  var nav = document.getElementById("primary-nav");
  if (toggle && nav) {
    toggle.addEventListener("click", function () {
      var open = nav.classList.toggle("is-open");
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
    });
  }

  var years = document.querySelectorAll("[data-year]");
  for (var i = 0; i < years.length; i++) {
    years[i].textContent = String(new Date().getFullYear());
  }

  var form = document.getElementById("contact-form");
  var status = document.getElementById("form-status");
  if (form && status) {
    form.addEventListener("submit", function (event) {
      event.preventDefault();
      var required = form.querySelectorAll("[required]");
      for (var j = 0; j < required.length; j++) {
        if (!required[j].value.trim()) {
          status.textContent = "Please complete the required fields.";
          required[j].focus();
          return;
        }
      }
      status.textContent = "Thanks — your message has been queued. We reply within one business day.";
      form.reset();
    });
  }
})();
