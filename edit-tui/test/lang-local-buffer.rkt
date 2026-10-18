#lang racket

;;; edit-tui/test/lang-local-buffer.rkt —— 本地 require：内存 buffer 优先于磁盘
;;;
;;; 场景：
;;;   main.rkt   (require "sub/../helper.rkt")
;;;   helper.rkt 磁盘上是 (provide disk-fn)，但已经在编辑器里打开，buffer 里是
;;;              (provide memory-fn)（未保存）。
;;; 期望：
;;;   · 路径里的 "sub/.." 被归一，补全从**内存 buffer**拿到 memory-fn，而不是 disk-fn；
;;;   · docs 查询重命名 / 本地模块时也从内存拿 local-def，不用 xref 查 (file ...)。

(require rackunit
         racket/async-channel
         racket/file
         racket/path
         racket/string
         "../command/key.rkt"
         (prefix-in app: "../base/event.rkt")
         "../base/id.rkt"
         "../base/transition.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../model/chrome.rkt"
         "../model/input.rkt"
         "../effects/engine.rkt"
         "../bootstrap/panel.rkt"
         "../chrome/slot.rkt"
         "../projection/render.rkt"
         "../plugins/docs/plugin.rkt"
         "../plugins/completion/plugin.rkt"
         "../plugins/builtin.rkt"
         "../runtime/run.rkt"
         "../dispatch/hooks.rkt"
         "../../core/editor/query.rkt"
         "../../core/editor/state.rkt"
         "../../core/text/base/point.rkt")

(define dir (make-temporary-file "edit-tui-local-buffer-~a" 'directory))
(define main-path (build-path dir "main.rkt"))
(define helper-path (build-path dir "helper.rkt"))
(define sub (build-path dir "sub"))
(make-directory* sub)

;; 磁盘上的 helper 故意提供另一个名字：如果误用磁盘，补全会给出 disk-fn。
(display-to-file "#lang racket\n(provide disk-fn)\n(define (disk-fn) 'disk)\n"
                 helper-path #:exists 'truncate)

(define main-text "#lang racket\n(require \"sub/../helper.rkt\")\n")
(define helper-text "#lang racket\n(provide memory-fn)\n(define (memory-fn x) x)\n")

(define main-did (doc-id 1))
(define helper-did (doc-id 2))
(define main-vid (view-id 1))
(define editor-rid (region-id 1))
(define docs-rid (region-id 2))
(define completion-rid (region-id 3))

(define engine (make-engine))
(void (engine-create-doc! engine main-did "main.rkt" main-text))
(void (engine-create-doc! engine helper-did "helper.rkt" helper-text))
(void (engine-create-view! engine main-vid main-did))

(define ws
  (let* ([ws (workspace-empty)]
         [ws (workspace-add-doc ws main-did
                                (make-doc-meta "main.rkt" #:path main-path
                                               #:saved-version
                                               (engine-view-doc-version
                                                (make-engine-view engine) main-did)))]
         [ws (workspace-add-doc ws helper-did
                                (make-doc-meta "helper.rkt" #:path helper-path
                                               #:saved-version
                                               (engine-view-doc-version
                                                (make-engine-view engine) helper-did)))]
         [ws (workspace-add-view ws main-vid (view-meta main-did (hash)))]
         [ws (workspace-add-region ws editor-rid
                                   (region editor-rid (list (view-member main-vid))
                                           main-vid 'editor))])
    ws))

(define lay
  (make-split 'lr
              (list (make-leaf editor-rid (flex 1))
                    (make-leaf docs-rid (flex 1)))
              (flex 1)))
(define s0 (make-state #:workspace (struct-copy workspace ws [layout lay])
                       #:ids (make-id-counter 3 2 3 1)))
(define s1 (install-docs-panel! engine s0 docs-rid))
(define s2 (install-completion-popup! engine s1 completion-rid))
(define s3 (state-workspace* s2 (λ (w)
                                  (struct-copy workspace w
                                               [layout (tree-hide (workspace-layout w) docs-rid)]))))
(define s4 (startup! editor-env engine (state-set-focus s3 main-vid)))

(define (feed s . evs)
  (transition-state (process-events editor-env engine (make-async-channel) s evs)))
(define (plain c) (app:key-event (key c)))
(define (ctrl c) (app:key-event (key c 'ctrl)))
(define (popup-text s)
  (engine-view-view-text (make-engine-view engine) (completion-popup-view s)))
(define (docs-text s)
  (engine-view-view-text (make-engine-view engine) (docs-panel-view s)))

;; 光标移到 require 行之后的新行
(define s5 (feed s4 (app:key-event (key 'end))
                 (app:key-event (key 'down)) (app:key-event (key 'end))
                 (app:key-event (key 'enter))))

;; 输入 memory-f：自动补全应该从内存 helper 里给出 memory-fn，而不是磁盘的 disk-fn
(define s6 (for/fold ([s s5]) ([c (in-string "memory-f")]) (feed s (plain c))))
(check-true (completion-open? s6))
(check-true (string-contains? (popup-text s6) "memory-fn"))
(check-false (string-contains? (popup-text s6) "disk-fn"))

;; 补全选中 memory-fn 时，docs 面板自动显示内存 buffer 里的 local-def
(check-true (docs-open? s6))
(check-true (string-contains? (docs-text s6) "define (memory-fn"))

(delete-directory/files dir)

(displayln "edit-tui lang-local-buffer: ok")
