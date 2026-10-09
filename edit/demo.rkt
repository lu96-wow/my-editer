#lang racket

;;; edit/demo.rkt —— 最小可跑装配：core editor（文档 / 视图真身仓）+ 布局骨架 + 编辑区。
;;;
;;; document / view 真身在 core editor；edit 只加布局树、focus、文档级键表。

(require "core/layout.rkt" "core/focus.rkt"
         "command/command.rkt" "command/keys.rkt" "command/binding.rkt"
         "../core/editor.rkt")

(provide demo-session)

(define (demo-session [w 80] [h 24])
  ;; 开 4 篇文档
  (define s0 (session-new (make-blank-editor) #f #f (focus-new #f) w h (list base-keys)))
  (define-values (s1 pid)  (session-open-document s0 (document-open "file tree\nsrc/\n  main.rkt")))
  (define-values (s2 bid)  (session-open-document s1 (document-open "  main.rkt  L1:C1")))
  (define-values (s3 did1) (session-open-document s2 (document-open "hello\nworld\nfoo\nbar\nbaz")))
  (define-values (s4 did2) (session-open-document s3 (document-open "second pane\nline2\nline3")))

  ;; 每篇文档建一个视图（vid 由 core 分配）
  (define-values (s5 panel) (session-add-view s4 pid  30 24))
  (define-values (s6 bar)   (session-add-view s5 bid  60  1))
  (define-values (s7 v1)    (session-add-view s6 did1 40 22))
  (define-values (s8 v2)    (session-add-view s7 did2 40 22))

  ;; document 专属命令：打开 did1 时给它绑 C-r
  (define s9 (session-doc-add-key s8 did1 (key 'r 'ctrl) (cmd-scroll 3)))

  ;; 布局：编辑区（运行时构造）+ 声明骨架（slot 留洞），叶子是 vid
  (define frame (split 'lr (list (cons 'flex (leaf v1)) (cons 'flex (leaf v2)))))
  (define base  (split 'lr (list (cons 30 (slot 'panel))
                                 (cons 'flex (split 'tb (list (cons 'flex (slot 'editor))
                                                              (cons 1 (slot 'bar))))))))

  (struct-copy session s9
    [layout base]
    [bindings (hash 'panel (leaf panel) 'bar (leaf bar) 'editor frame)]
    [focus (focus-new v1)]))

(module+ main
  (require "tui.rkt")
  (run-tui (demo-session)))
