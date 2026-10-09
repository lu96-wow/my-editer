#lang racket

;;; edit/demo.rkt —— 最小可跑装配：编辑区 + 四个状态窗口（输入 / 状态 / 文件树 / 缓冲区）。

(require "core/layout.rkt" "core/focus.rkt"
         "command/session.rkt" "command/command.rkt" "command/keys.rkt" "command/binding.rkt"
         "document/document.rkt"
         "feature/status.rkt" "feature/buffers.rkt" "feature/tree.rkt" "feature/prompt.rkt")

(provide demo-session)

(define (demo-session [w 80] [h 24])
  (define s0 (session-blank w h (list base-keys)))

  ;; 编辑文档
  (define-values (s1 did1) (session-open-document s0 "hello\nworld\nfoo\nbar\nbaz" #:name "main.rkt"))
  (define-values (s2 did2) (session-open-document s1 "second pane\nline2\nline3" #:name "notes.txt"))
  (define-values (s3 v1)   (session-add-view s2 did1 40 18))
  (define-values (s4 v2)   (session-add-view s3 did2 40 18))
  ;; document 专属命令：did1 绑 C-r
  (define s5 (session-doc-add-key s4 did1 (key 'r 'ctrl) (cmd-scroll 3)))

  ;; 状态窗口：输入行 / 状态行 / 文件树 / 缓冲区
  (define-values (s6 input)  (prompt-install s5 w 1))
  (define-values (s7 status) (status-install s6 w 1))
  (define-values (s8 tree)   (tree-install s7 (current-directory) 26 18))
  (define-values (s9 buf)    (buffers-install s8 26 8))
  ;; tree / buffers 共用左栏位置，默认显示 tree
  (define s9* (session-set-visible s9 buf #f))

  ;; 布局
  (define side   (stack (list (leaf tree) (leaf buf))))
  (define editor (split 'lr (list (cons 'flex (leaf v1)) (cons 'flex (leaf v2)))))
  (define bottom (split 'tb (list (cons 'flex (leaf status)) (cons 1 (leaf input)))))
  (define base   (split 'lr (list (cons 26 (slot 'side))
                                  (cons 'flex (split 'tb (list (cons 'flex (slot 'editor))
                                                               (cons 2 (slot 'bottom))))))))

  (define bnd (hash 'side side 'editor editor 'bottom bottom))
  (define s10 (document-install (session-assemble s9* base bnd)))
  ;; 初始焦点 / 活动编辑视图
  (session-set-focus s10 (focus-set (session-focus s10) v1)))

(module+ main
  (require "tui.rkt")
  (run-tui (demo-session)))
