#lang racket

;;; edit/demo.rkt —— 最小可跑装配：document 层 + 声明骨架 + 编辑区 frame。

(require "view.rkt" "layout.rkt" "focus.rkt" "command.rkt" "keys.rkt" "binding.rkt"
         "../core/text/document.rkt")

(provide demo-session)

(define (demo-session [w 80] [h 24])
  ;; 从空 session 起，一个个开 document（拿到 did）
  (define s0 (session (hash) 0 #f (hash) (focus-new #f) w h #f (list base-keys)))
  (define-values (s1 pid) (session-open-document s0 (document-open "file tree\nsrc/\n  main.rkt")))
  (define-values (s2 bid) (session-open-document s1 (document-open "  main.rkt  L1:C1")))
  (define-values (s3 d1)  (session-open-document s2 (document-open "hello\nworld\nfoo\nbar\nbaz")))
  (define-values (s4 d2)  (session-open-document s3 (document-open "second pane\nline2\nline3")))

  ;; 视图只持 did
  (define pv (view-open 'panel pid 0 0 1 1))
  (define bv (view-open 'bar   bid 0 0 1 1))
  (define v1 (view-open 'v1    d1  0 0 1 1))
  (define v2 (view-open 'v2    d2  0 0 1 1))

  ;; 编辑区 frame（运行时构造的子树）+ 声明骨架（slot 留洞）
  (define frame (split 'lr (list (cons 'flex (leaf v1)) (cons 'flex (leaf v2)))))
  (define base  (split 'lr (list (cons 30 (slot 'panel))
                                 (cons 'flex (split 'tb (list (cons 'flex (slot 'editor))
                                                              (cons 1 (slot 'bar))))))))

  ;; document 专属命令：打开 d1 时给它绑 C-r（只有 d1 有）
  (define s5 (session-doc-add-key s4 d1 (key 'r 'ctrl) (cmd-scroll 3)))

  (struct-copy session s5
    [layout base]
    [bindings (hash 'panel (leaf pv) 'bar (leaf bv) 'editor frame)]
    [focus (focus-new 'v1)]))

(module+ main
  (require "tui.rkt")
  (run-tui (demo-session)))
