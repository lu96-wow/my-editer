#lang racket

;;; 分层约束的可执行版本：
;;;
;;;   骨架（core/skeleton.rkt） ← 插件（edit / chrome / filetree） ← app 编排 ← boot
;;;
;;; 规则：
;;;   - 骨架不认识 app / 插件 / boot；
;;;   - 插件只 require core/skeleton.rkt（不直接拿骨架实现模块），
;;;     插件之间只经对方 api.rkt；可以 require app/state 等 app 基础；
;;;   - app 基础只 require 骨架；
;;;   - app/step 只 require 骨架 + app 基础 + 插件 api.rkt；
;;;   - boot 可以 require 一切（它是唯一副作用 / 启动层）。
(require rackunit
         racket/file
         racket/path
         racket/string)

(define test-dir (path->complete-path (find-system-path 'run-file)))
(define root (simplify-path (build-path (path-only test-dir) 'up)))

(define (read-forms rel)
  (define text (regexp-replace #rx"^#lang[^\n]*\n"
                               (file->string (build-path root rel))
                               ""))
  (with-input-from-string text
    (λ ()
      (let loop ([acc '()])
        (define x (read))
        (if (eof-object? x) (reverse acc) (loop (cons x acc)))))))

(define (all-strings x)
  (cond
    [(string? x) (list x)]
    [(symbol? x) (list (symbol->string x))]
    [(list? x) (append* (for/list ([e (in-list x)]) (all-strings e)))]
    [else '()]))

;; 模块的 require 目标（路径字符串 + 裸模块名）
(define (requires rel)
  (append*
   (for/list ([f (in-list (read-forms rel))]
              #:when (and (list? f) (eq? (car f) 'require)))
     (append* (for/list ([spec (in-list (cdr f))]) (all-strings spec))))))

(define (requires-any? rel pattern)
  (for/or ([r (in-list (requires rel))]) (regexp-match? pattern r)))

;; 骨架实现文件（插件不许直接拿）
(define skeleton-impl?
  #rx"(^|/)core/(base|command|face|panel|layout|focus|projection|resource|engine)/[^/]+\\.rkt$")
;; 插件的实现文件（跨插件只许 api.rkt）
(define plugin-impl?
  #rx"(^|/)(edit|chrome|filetree)/[^/]+\\.rkt$")
(define upper-layer? #rx"(^|/)(app|chrome|filetree|edit|boot)/")
;; 外部 core（repo/core）也不许插件直接摸；本地 core 只许 skeleton.rkt
(define external-core? #rx"(^|/)\\.\\./\\.\\./core/")

;;; ════════════════ 骨架 ════════════════
(define skeleton-files
  '("core/base/api.rkt"
    "core/command/key.rkt" "core/command/table.rkt" "core/command/api.rkt"
    "core/layout/config.rkt"
    "core/face/model.rkt" "core/face/api.rkt"
    "core/panel/model.rkt" "core/panel/api.rkt"
    "core/layout/tree.rkt" "core/layout/solve.rkt" "core/layout/ops.rkt" "core/layout/api.rkt"
    "core/focus/model.rkt" "core/focus/api.rkt"
    "core/projection/borders.rkt" "core/projection/geometry.rkt" "core/projection/api.rkt"
    "render/theme.rkt" "render/core.rkt" "render/layout.rkt" "render/api.rkt"
    "core/resource/model.rkt" "core/resource/api.rkt"
    "core/engine/action.rkt" "core/engine/store.rkt" "core/engine/api.rkt"))

(for ([m (in-list skeleton-files)])
  (check-false (requires-any? m upper-layer?) m)
  (check-false (requires-any? m #rx"(^|/)skeleton/") m))

;; 骨架内部顺序
(check-false (requires-any? "core/layout/tree.rkt" #rx"(^|/)(solve|ops)\\.rkt$"))
(check-false (requires-any? "core/layout/solve.rkt" #rx"(^|/)ops\\.rkt$"))
(check-true (requires-any? "core/layout/solve.rkt" #rx"(^|/)tree\\.rkt$"))
(check-true (requires-any? "core/layout/ops.rkt" #rx"(^|/)(tree|solve)\\.rkt$"))
(check-true (requires-any? "core/projection/geometry.rkt" #rx"(^|/)borders\\.rkt$"))
; engine 不认识 app（action 词汇也在骨架里）
(check-false (requires-any? "core/engine/store.rkt" #rx"(^|/)app/"))

;; 骨架入口本身只聚合骨架 api
(check-false (requires-any? "core/skeleton.rkt" upper-layer?) "core/skeleton.rkt")

;; 骨架不认识任何具体配置（配置是宿主的，不是 layout / command 的）
(check-false (requires-any? "core/skeleton.rkt" #rx"(^|/)config/") "core/skeleton.rkt")
(check-false (requires-any? "core/layout/config.rkt" #rx"(^|/)config/layout/")
              "core/layout/config.rkt")

;; 配置模型在 layout 内部：ops / api / focus 都用它，但不反向依赖 config/
(check-true (requires-any? "core/layout/api.rkt" #rx"(^|/)config\\.rkt$")
            "core/layout/api.rkt")
(check-true (requires-any? "core/layout/ops.rkt" #rx"(^|/)config\\.rkt$")
            "core/layout/ops.rkt")
(check-true (requires-any? "core/focus/model.rkt" #rx"(^|/)layout/config\\.rkt$")
            "core/focus/model.rkt")

;; 纯配置只依赖 layout API，不依赖 app / plugin / runtime
(check-true (requires-any? "config/layout/default.rkt" #rx"(^|/)core/layout/api\\.rkt$")
            "config/layout/default.rkt")
(check-false (requires-any? "config/layout/default.rkt" upper-layer?)
              "config/layout/default.rkt")
(check-false (requires-any? "config/layout/default.rkt" #rx"(^|/)boot/")
              "config/layout/default.rkt")

;; keymap 配置允许 require 插件 / app 命令 API，但必须纯组合：
;; 不 require step / main / runtime（否则会出现配置 <- 编排的反向依赖）。
(check-false (requires-any? "config/keymap/default.rkt" #rx"(^|/)app/step\\.rkt$")
              "config/keymap/default.rkt")
(check-false (requires-any? "config/keymap/default.rkt" #rx"(^|/)main\\.rkt$")
              "config/keymap/default.rkt")
(check-false (requires-any? "config/keymap/default.rkt" #rx"(^|/)boot/")
              "config/keymap/default.rkt")

;; 旧位置不再存在（config 只放纯数据）
(check-false (file-exists? (build-path root "config/api.rkt")))
(check-false (file-exists? (build-path root "config/model.rkt")))

;;; ════════════════ 插件（edit / chrome / filetree） ════════════════
(define plugin-files
  '("edit/insert.rkt" "edit/commands.rkt" "edit/api.rkt"
    "chrome/status.rkt" "chrome/input.rkt" "chrome/api.rkt"
    "filetree/model.rkt" "filetree/lines.rkt" "filetree/scan.rkt"
    "filetree/slice.rkt" "filetree/sync.rkt" "filetree/commands.rkt"
    "filetree/api.rkt"))

(for ([m (in-list plugin-files)])
  ;; 不许摸外部 core / boot / 骨架实现；本地 core 只经 core/skeleton.rkt
  (check-false (requires-any? m external-core?) m)
  (check-false (requires-any? m #rx"(^|/)boot/") m)
  (check-false (requires-any? m skeleton-impl?) m)
  ;; 骨架只经 core/skeleton.rkt
  (for ([r (in-list (requires m))]
        #:when (regexp-match? #rx"(^|/)core/skeleton\\.rkt$" r))
    (check-true (regexp-match? #rx"core/skeleton\\.rkt$" r) (format "~a -> ~a" m r)))
  ;; 跨插件只经对方 api.rkt
  (for ([r (in-list (requires m))]
        #:when (regexp-match? plugin-impl? r))
    (check-true (regexp-match? #rx"/api\\.rkt$" r) (format "~a -> ~a" m r))))

;; 插件组合骨架：至少用到 core/skeleton.rkt（api.rkt / 纯 model 例外）
(for ([m (in-list '("edit/commands.rkt" "chrome/status.rkt" "chrome/input.rkt"
                    "filetree/sync.rkt" "filetree/commands.rkt"))])
  (check-true (for/or ([r (in-list (requires m))])
                (regexp-match? #rx"core/skeleton\\.rkt$" r))
              m))

;; 纯投影 / 状态不碰 IO
(check-false (requires-any? "filetree/lines.rkt" #rx"(^|/)scan\\.rkt$"))
(check-false (requires-any? "filetree/model.rkt" upper-layer?))

;;; ════════════════ app 基础 / 编排 ════════════════
(for ([m (in-list '("app/state.rkt" "app/keymap.rkt" "app/event.rkt"
                    "app/action.rkt" "app/commands.rkt" "app/placement.rkt"
                    "app/step.rkt"))])
  (check-false (requires-any? m skeleton-impl?) m)
  (check-false (requires-any? m external-core?) m)
  (check-false (requires-any? m #rx"(^|/)boot/") m)
  (for ([r (in-list (requires m))]
        #:when (regexp-match? plugin-impl? r))
    (check-true (regexp-match? #rx"/api\\.rkt$" r) (format "~a -> ~a" m r))))

;; app/state 只依赖骨架（+ 自己）
(check-false (requires-any? "app/state.rkt" #rx"(^|/)(chrome|edit|filetree)/"))
(check-false (requires-any? "app/state.rkt" #rx"(^|/)step\\.rkt$"))

;;; ════════════════ 入口 ════════════════
;; 顶层 api 只聚合 api.rkt（允许 */api.rkt，不许实现文件）
(define (impl-require? rel)
  (for/or ([r (in-list (requires rel))])
    (and (or (regexp-match? skeleton-impl? r)
             (regexp-match? plugin-impl? r))
         (not (regexp-match? #rx"api\\.rkt$" r)))))

;; main 是唯一聚合入口（没有顶层 api.rkt）
(check-false (impl-require? "main.rkt") "main.rkt")
(check-false (file-exists? (build-path root "api.rkt")) "顶层不应再有 api.rkt")

; 骨架 demo 也只走 main API
(check-false (requires-any? "demo/layout.rkt" skeleton-impl?) "demo/layout.rkt")

(displayln "edit-tui-rebuild/test/layers.rkt: ok")
