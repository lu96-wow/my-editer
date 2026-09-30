#lang racket

;;; ============================================================================
;;; command.rkt —— 命令块：全局键位表 + 分发
;;; ============================================================================
;;;
;;; 「命令」这一块只含**作用于全局**的东西 —— 目前是空表，留给以后定焦点/布局键。
;;; 每个文档自己的按键不在这里：树在 tree.rkt，编辑格在 editor.rkt。
;;;
;;; 分发顺序：
;;;   1) 输入是 key 且命中 global-keys → 执行壳动作；
;;;   2) 否则 handle*：resize / 鼠标 / 交给焦点 pane 自己的 input。
;;;
;;; 另外：开/关文件会改 opened，此时让树重新投影（刷新已打开文件的颜色）。

(require "editor.rkt"
         "layout.rkt"
         "tree.rkt"
         "input.rkt")

(provide handle global-keys)

;;; ---------- 全局键位表 ----------

;; 全局键：Ctrl-, / Ctrl+. 调焦点窗口宽度；Ctrl-Q 退出（先逐个问未保存的编辑器）。
(define global-keys
  (hash (key #\, #t #f #f #f) (lambda (a) (editor-resize-focus a -1))
        (key #\. #t #f #f #f) (lambda (a) (editor-resize-focus a +1))
        (key #\q #t #f #f #f) quit-request))

(define (global-action in) (and (key? in) (hash-ref global-keys in #f)))

;;; ---------- 退出问答（y 保存 / n 跳过 / Esc 取消） ----------

(define (plain-key? in)
  (and (key? in) (not (key-ctrl? in)) (not (key-alt? in)) (not (key-meta? in))))

(define (quit-answer a in)
  (cond
    [(plain-key? in)
     (define n (key-name in))
     (cond
       [(and (char? n) (char=? (char-downcase n) #\y)) (quit-save-current a)]
       [(and (char? n) (char=? (char-downcase n) #\n)) (quit-skip-current a)]
       [(eq? n 'escape) (quit-cancel a)]
       [else a])]
    [else a]))

;;; ---------- 分发 ----------

(define (handle a in)
  (define a1
    (cond
      [(resize? in) (struct-copy app a [rows (resize-rows in)] [cols (resize-cols in)])]
      [(app-quit-ask a) (quit-answer a in)]                    ; 退出问答优先
      [(global-action in) ((global-action in) a)]
      [else (handle* a in)]))
  ;; 开/关文件改了 opened、调宽改了 layout、切视图改了 panes → 树重建（颜色 / 视图表 / 宽度）；
  ;; 视图模式还会随每次处理重建，让表里的活动视图 / L C 保持最新。
  (define tpid (app-pid-of-kind a1 'tree))
  (define views? (and tpid
                      (eq? (tree-mode (pane-state (app-pane a1 tpid))) 'views)))
  (if (and tpid
           (or views?
               (not (equal? (app-opened a) (app-opened a1)))
               (not (equal? (app-layout a) (app-layout a1)))
               (not (equal? (app-panes a) (app-panes a1)))))
      (tree-project! a1 tpid)
      a1))

(define (handle* a in)
  (cond
    [(resize? in) (struct-copy app a [rows (resize-rows in)] [cols (resize-cols in)])]

    ;; 鼠标：layout 命中 → pane-id → 点谁谁获焦 → 交局部坐标给该 pane
    [(pointer? in)
     (define pid (layout-hit (app-layout a) (app-cols a) (app-rows a)
                             (pointer-row in) (pointer-col in)))
     (cond
       [(not pid) a]
       [else
        (define p (app-pane a pid))
        (define a1 (if (pane-focusable? p) (focus-set a pid) a))
        (define f (pane-pointer p))
        (cond
          [(not f) a1]
          [else
           (define r (app-pane-rect a1 pid))
           (f a1 pid in (- (pointer-row in) (lrect-y r)) (- (pointer-col in) (lrect-x r)))])])]

    ;; 键盘 / 文本：交给焦点 pane 自己的 input
    [else
     (define p (app-pane a (app-focus a)))
     (define f (pane-input p))
     (if f (f a (app-focus a) in) a)]))
