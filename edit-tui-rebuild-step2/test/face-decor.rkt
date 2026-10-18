#lang racket

;;; edit-tui/test/face-decor.rkt —— 增量 face decor
;;;
;;; 覆盖：
;;;   1. 初次 open：前景 / 背景两层都写到 core face port；
;;;   2. 编辑：只改脏行，跨行词法状态正确扩散；
;;;   3. undo / redo：decor 状态和 face 跟着 document 版本回来；
;;;   4. after-edit 参数带 changes；
;;;   5. 文本编辑后静态层仍与文本对齐，不越界。

(require rackunit
         racket/async-channel
         "../command/key.rkt"
         (prefix-in app: "../base/event.rkt")
         "../base/id.rkt"
         "../base/signal.rkt"
         "../base/transition.rkt"
         "../base/effect.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../model/face-layer.rkt"
         "../model/face-decor.rkt"
         "../effects/engine.rkt"
         "../effects/interpreter.rkt"
         "../plugins/builtin.rkt"
         "../plugins/highlight/plugin.rkt"
         "../plugins/highlight/depth-plugin.rkt"
         "../env/environment.rkt"
         "../env/plugin.rkt"
         "../env/mode.rkt"
         "../env/defaults.rkt"
         "../base/keymap.rkt"
         "../runtime/run.rkt"
         "../base/face.rkt"
         "../../core/editor/query.rkt"
         "../../core/text/base/point.rkt"
         "../../core/text/base/selection.rkt"
         "../../core/text/base/change.rkt")

(define did (doc-id 1))
(define vid (view-id 1))
(define rid (region-id 1))

(define (fg name) (face-set-fg face-empty name))
(define (bg name) (face-set-bg face-empty name))
(define (fg-at b l c) (define f (buffer-face-at b l c)) (and f (not (symbol? f)) (face-fg f)))
(define (bg-at b l c) (define f (buffer-face-at b l c)) (and f (not (symbol? f)) (face-bg f)))

(define (make-env)
  (plugins-env
   (environment-merge default-environment
                      (make-environment #:modes (hash 'text (make-mode #:fallback 'insert))
                                        #:keymaps (hash 'global (keys))))
   (list (depth-bg-plugin) (highlight-plugin))))

(define (make-world text)
  (define engine (make-engine))
  (void (engine-create-doc! engine did "m.rkt" text))
  (void (engine-create-view! engine vid did))
  (define ws
    (let* ([ws (workspace-empty)]
           [ws (workspace-add-doc ws did (make-doc-meta "m.rkt" #:path "/tmp/m.rkt"))]
           [ws (workspace-add-view ws vid (view-meta did (hash)))]
           [ws (workspace-add-region ws rid (region rid (list (view-member vid)) vid 'editor))])
      (struct-copy workspace ws [layout (make-leaf rid)])))
  (define s0 (state-set-focus (make-state #:workspace ws) vid))
  (define env (make-env))
  (values engine (startup! env engine s0) env))

;;; ════════════════ 1. 初次 open ════════════════

(let-values ([(engine s0 env) (make-world "(define (square x) (* x x))")])
  (define b (engine-doc-buffer engine did))
  (check-equal? (fg-at b 0 1) 'fg-syntax-def)
  (check-equal? (bg-at b 0 0) 'bg-depth-1)
  (check-equal? (bg-at b 0 9) 'bg-depth-2)
  (void s0) (void env))

;;; ════════════════ 2. 编辑：脏行 + 跨行状态 ════════════════

(let-values ([(engine s0 env) (make-world "(a)\n(b)\n(c)")])
  (define b (engine-doc-buffer engine did))
  (define (run effect) (interpret-effect! engine s0 effect))
  (void env)
  ;; 行首插入 #|：块注释从第 0 行扩散到后面所有行
  (run (select-effect vid (selections-one (caret (point 0 0)))))
  (run (insert-text-effect vid "#|"))
  (check-equal? (buffer-string b) "#|(a)\n(b)\n(c)")
  (check-equal? (fg-at b 1 0) 'fg-syntax-comment)
  (check-equal? (fg-at b 2 0) 'fg-syntax-comment)

  ;; undo：decor 状态和 face 跟着旧 document 回来
  (run (undo-effect vid))
  (check-equal? (buffer-string b) "(a)\n(b)\n(c)")
  (check-false (fg-at b 1 0))
  ;; redo：注释又回来
  (run (redo-effect vid))
  (check-equal? (buffer-string b) "#|(a)\n(b)\n(c)")
  (check-equal? (fg-at b 1 0) 'fg-syntax-comment))

;;; ════════════════ 3. after-edit 带 changes ════════════════

(let-values ([(engine s0 env) (make-world "abc")])
  (void env)
  (define t (interpret-effect! engine s0 (select-effect vid (selections-one (caret (point 0 0))))))
  (define s1 (transition-state t))
  (define t2 (interpret-effect! engine s1 (insert-text-effect vid "x")))
  (define s2 (transition-state t2))
  (define sig
    (for/first ([g (in-list (signals-queue (state-signals s2)))]
                #:when (eq? (signal-point g) 'after-edit))
      g))
  (check-not-false sig)
  (check-equal? (car (signal-args sig)) did)
  (define changes (cadr (signal-args sig)))
  (check-true (pair? changes))
  (check-equal? (change-kind (car changes)) 'insert))

;;; ════════════════ 4. 静态层在编辑后仍对齐 ════════════════

(let-values ([(engine s0 env) (make-world "abcdef")])
  (void env)
  (define b (engine-doc-buffer engine did))
  (engine-set-face-layers! engine '(bg))
  (engine-set-face-layer! engine did 'bg (list (list 0 0 0 6 (bg 'bg-static))))
  (check-equal? (bg-at b 0 0) 'bg-static)
  (engine-apply! engine (select-effect vid (selections-one (caret (point 0 0)))))
  (engine-apply! engine (insert-text-effect vid "\n"))
  ;; 旧格随文本平移到第 1 行；不越界、不崩
  (check-equal? (buffer-string b) "\nabcdef")
  (check-equal? (bg-at b 1 0) 'bg-static)
  (void s0))

;;; ════════════════ 5. 增量：只重扫脏行，状态收敛即停 ════════════════

(define scan-count (box 0))

(define (count-open _path text)
  (define lines (track->list text))
  (set-box! scan-count (length lines))
  (values (track-of-list (for/list ([line (in-list lines)]) (string-length line)))
          (track-of-list (for/list ([line (in-list lines)])
                           (make-vector (string-length line) #f)))))

(define (count-change state layer ctx)
  (define changes (face-ctx-changes ctx))
  (cond
    [(null? changes) (values state layer (dirty-lines '()))]
    [else
     (stateful-advance
      state layer (face-ctx-new-text ctx) changes
      (lambda (st ln line)
        (set-box! scan-count (add1 (unbox scan-count)))
        (values (string-length line) (make-vector (string-length line) #f)))
      #f)]))

(define count-decor
  (face-decor 'count 'count-layer (lambda (_dm) #t) count-open count-change))

(let ()
  (define engine (make-engine))
  (void (engine-create-doc! engine did "m.rkt" "a\nb\nc\nd\ne"))
  (void (engine-create-view! engine vid did))
  (engine-set-face-layers! engine '(count-layer))
  (engine-attach-decors! engine did (list count-decor) "/tmp/m.rkt")
  (check-equal? (unbox scan-count) 5)        ; open 整篇扫 5 行
  (set-box! scan-count 0)
  (void (engine-apply! engine (select-effect vid (selections-one (caret (point 0 0))))))
  (void (engine-apply! engine (insert-text-effect vid "x")))
  ;; 第 0 行长度变了 -> 重扫；第 1 行状态与旧值相同 -> 收敛停。
  (check-equal? (unbox scan-count) 2))

;;; ════════════════ 5b. 多光标：多个不相邻脏行都重扫 ════════════════

(let ()
  (define engine (make-engine))
  (void (engine-create-doc! engine did "m.rkt" "a\nb\nc\nd\ne"))
  (void (engine-create-view! engine vid did))
  (engine-set-face-layers! engine '(count-layer))
  (engine-attach-decors! engine did (list count-decor) "/tmp/m.rkt")
  (set-box! scan-count 0)
  (void (engine-apply!
         engine
         (select-effect vid
                        (selections-of (list (caret (point 0 0))
                                             (caret (point 3 0)))))))
  (void (engine-apply! engine (insert-text-effect vid "x")))
  ;; core 会从右到左拆成两次 fork：行 3 run 扫 3→4，行 0 run 扫 0→1。
  (check-equal? (unbox scan-count) 4))

;;; ════════════════ 5c. 多光标：两次 fork 的脏行都要写回 ════════════════

(let-values ([(engine s0 env) (make-world "(a)\n(b)\n(c)\n(d)")])
  (void env)
  (define b (engine-doc-buffer engine did))
  (define (run effect) (transition-state (interpret-effect! engine s0 effect)))
  (define s1 (run (select-effect vid
                                (selections-of (list (caret (point 0 0))
                                                     (caret (point 3 0)))))))
  (void s1)
  (run (insert-text-effect vid "define"))
  (check-equal? (fg-at b 0 0) 'fg-syntax-def)
  (check-equal? (fg-at b 3 0) 'fg-syntax-def))
