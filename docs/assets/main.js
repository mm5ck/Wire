document.addEventListener("DOMContentLoaded", function () {
	var toggle = document.querySelector(".menu-toggle");
	var sidebar = document.querySelector(".sidebar");

	if (toggle && sidebar) {
		toggle.addEventListener("click", function () {
			sidebar.classList.toggle("open");
		});

		document.querySelectorAll(".sidebar a").forEach(function (link) {
			link.addEventListener("click", function () {
				sidebar.classList.remove("open");
			});
		});
	}
});
