// O unico script do site, servido do proprio site (CSP script-src 'self'). Sem ele tudo
// continua legivel: os videos mostram a capa, a lista de tokens aparece inteira e o
// menu do celular abre pelo <details>. Com ele: os videos tocam so quando aparecem na
// tela (e param ao sair), cada um com botao de pausar, nada toca sozinho com
// "reduzir movimento" ligado, e a lista de tokens ganha a busca.
(function () {
  "use strict";

  var raiz = document.documentElement;
  raiz.classList.add("js");

  var calmo = window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)") : { matches: false };
  var videos = Array.prototype.slice.call(document.querySelectorAll("video[data-auto]"));

  function botaoDe(video) {
    var aparelho = video.closest(".aparelho");
    return aparelho ? aparelho.querySelector(".pausar") : null;
  }

  function mostrar(video, estado) {
    var botao = botaoDe(video);
    if (!botao) return;
    botao.setAttribute("data-estado", estado);
    botao.setAttribute("aria-label", estado === "pausado" ? "Tocar a animação" : "Pausar a animação");
  }

  function tocar(video) {
    video.muted = true;
    if (video.preload !== "auto") video.preload = "auto";
    var promessa = video.play();
    mostrar(video, "tocando");
    if (promessa && promessa.catch) {
      promessa.catch(function () { mostrar(video, "pausado"); });
    }
  }

  videos.forEach(function (video) {
    mostrar(video, "pausado");
    // O video aparece por cima da capa so quando ja tem quadro para mostrar.
    video.addEventListener("playing", function () { video.classList.add("visivel"); });
    var botao = botaoDe(video);
    if (!botao) return;
    botao.addEventListener("click", function () {
      if (video.paused) {
        video.removeAttribute("data-parado");
        tocar(video);
      } else {
        video.setAttribute("data-parado", "");
        video.pause();
        mostrar(video, "pausado");
      }
    });
  });

  if (!calmo.matches && "IntersectionObserver" in window) {
    var observador = new IntersectionObserver(function (entradas) {
      entradas.forEach(function (entrada) {
        var video = entrada.target;
        if (entrada.isIntersecting && entrada.intersectionRatio >= 0.35) {
          if (!video.hasAttribute("data-parado") && video.paused) tocar(video);
        } else if (!video.paused) {
          video.pause();
          if (!video.hasAttribute("data-parado")) mostrar(video, "pausado");
        }
      });
    }, { threshold: [0, 0.35, 0.7] });
    videos.forEach(function (video) { observador.observe(video); });
  }

  // Busca na lista de tokens (redes/): por simbolo, nome ou rede.
  var campo = document.getElementById("busca-token");
  if (campo) {
    var itens = Array.prototype.slice.call(document.querySelectorAll("[data-busca]"));
    var vazio = document.getElementById("busca-vazia");
    var normalizar = function (texto) {
      return texto.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().trim();
    };
    campo.addEventListener("input", function () {
      var termo = normalizar(campo.value);
      var achados = 0;
      itens.forEach(function (item) {
        var mostra = !termo || item.getAttribute("data-busca").indexOf(termo) >= 0;
        item.hidden = !mostra;
        if (mostra) achados += 1;
      });
      if (vazio) vazio.hidden = achados > 0;
    });
  }
})();
