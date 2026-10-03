#lang racket

;;; lab/command/dispatch.rkt —— 派发：session × input → (values session effects)
;;;
;;; 解析顺序：
;;;   0. 输入行激活 → 作为 prompt 输入（回车确认 / Esc 取消）
;;;   1. resize → 更新 session 尺寸
;;;   2. session-apply-layout! 把尺寸落到各 view
;;;   3. 焦点 pane：树视图 → 树命令表；否则 → 该文档的每文档命令表
;;;   4. 未命中 → 默认命令表
;;;   5. 仍未命中 → 自插入（text / 无 Ctrl·Alt·Meta 的可打印键）
;;;   6. 最后 trees-refresh（打开标记 / 焦点高亮 / 文档树结构保持最新）

(require
 "base.rkt"
 "table.rkt"
 "default.rkt"
 "tree.rkt"
 "../input.rkt"
 "../model/session.rkt"
 "../model/document.rkt"
 "../model/edit.rkt"
 "../model/view.rkt"
 "../model/tree.rkt")

(provide dispatch active-command-table)

;; 焦点视图的命令表：树视图 → 树表；否则查该文档的每文档表。
(define (active-command-table s)
  (define a (active-view-id s))
  (cond
    [(not a) #f]
    [(tree-of-view s a) tree-table]
    [else (document-commands s (view-document-id s a))]))

(define (plain-mods? m)
  (not (or (modifiers-control m) (modifiers-alt m) (modifiers-meta m))))

(define (dispatch s in)
  (cond
    [(session-prompt s) (dispatch-prompt s in)]
    [else
     (define s0 (session-apply-layout! s))
     (match in
       [(resize rows cols) (values (session-resize s0 rows cols) '())]
       ;; 鼠标：layout 命中 → 切焦点 / 落光标 / 滚动
       [(mouse 'press 'left row col mods)
        (values (trees-refresh (click! s0 row col (modifiers-shift mods))) '())]
       [(mouse 'press _ row col _)
        (values (trees-refresh (focus-pane! s0 row col)) '())]
       [(mouse 'drag 'left row col _)
        (values (trees-refresh (click! s0 row col #t)) '())]
       [(wheel dir row col _)
        (values (trees-refresh (wheel! s0 dir row col)) '())]
       [_ (define-values (s* effs) (dispatch-normal s0 in))
          (values (trees-refresh s*) effs)])]))

(define (dispatch-normal s in)
  (define ctx (context (session-rows s) (session-cols s)))
  (define b (input->binding in))
  (define tbl (active-command-table s))
  (define cmd (and b (or (and tbl (table-lookup tbl b))
                         (table-lookup default-table b))))
  (cond
    [cmd ((command-proc cmd) s ctx in)]
    [else (self-insert s ctx in)]))

;;; ---------- 输入行 ----------

(define (dispatch-prompt s in)
  (define p (session-prompt s))
  (define t (prompt-text p))
  (define (set-text x) (session-set-prompt s (struct-copy prompt p [text x])))
  (cond
    [(text? in) (values (set-text (string-append t (text-string in))) '())]
    [(and (key? in) (char? (key-name in)) (plain-mods? (key-modifiers in)))
     (values (set-text (string-append t (string (key-name in)))) '())]
    [(and (key? in) (eq? (key-name in) 'backspace))
     (values (set-text (if (string=? t "") t (substring t 0 (sub1 (string-length t))))) '())]
    [(and (key? in) (eq? (key-name in) 'escape))
     (values (session-set-prompt s #f) '())]
    [(and (key? in) (eq? (key-name in) 'enter))
     (define s* ((prompt-on-confirm p) (session-set-prompt s #f) t))
     (values (trees-refresh s*) '())]
    [else (values s '())]))

;;; ---------- 自插入 ----------

(define (self-insert s ctx in)
  (define a (active-view-id s))
  (cond
    [(not a) (values s '())]
    [(text? in) (values (view-insert! s a (text-string in)) '())]
    [(and (key? in) (char? (key-name in)) (plain-mods? (key-modifiers in)))
     (values (view-insert! s a (string (key-name in))) '())]
    [else (values s '())]))
