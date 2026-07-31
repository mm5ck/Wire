document.addEventListener("DOMContentLoaded", function () {
	var toggle = document.querySelector(".menu-toggle");
	var sidebar = document.querySelector(".sidebar");
	var backdrop = document.querySelector(".sidebar-backdrop");

	if (!toggle || !sidebar) {
		return;
	}

	function openMenu() {
		sidebar.classList.add("open");
		if (backdrop) backdrop.classList.add("open");
		toggle.setAttribute("aria-expanded", "true");
	}

	function closeMenu() {
		sidebar.classList.remove("open");
		if (backdrop) backdrop.classList.remove("open");
		toggle.setAttribute("aria-expanded", "false");
	}

	toggle.addEventListener("click", function () {
		if (sidebar.classList.contains("open")) {
			closeMenu();
		} else {
			openMenu();
		}
	});

	if (backdrop) {
		backdrop.addEventListener("click", closeMenu);
	}

	document.querySelectorAll(".sidebar a").forEach(function (link) {
		link.addEventListener("click", closeMenu);
	});

	document.addEventListener("keydown", function (event) {
		if (event.key === "Escape") {
			closeMenu();
		}
	});
});
