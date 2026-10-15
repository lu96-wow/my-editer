#lang racket

;;; core/editor/history.rkt —— 纯文档版本栈：record / merge / set-current / undo / redo / 上限 / 开关。
(require rackunit
         "../../core/editor/history.rkt"
         "../../core/text/document.rkt")

(define d0 (document-open "0"))
(define d1 (document-open "1"))
(define d2 (document-open "2"))

;; ---------- 初始 ----------
(define h0 (history-open d0))
(check-false (history-can-undo? h0))
(check-false (history-can-redo? h0))
(check-equal? (history-depth h0) 0)
(check-eq? (history-document h0) d0)
(check-false (history-undo-target h0))
(check-false (history-redo-target h0))
(check-equal? (history-limit h0) default-history-limit)

;; ---------- record：新起一步并清 redo ----------
(define h1 (history-record h0 d0 d1))
(check-true (history-can-undo? h1))
(check-false (history-can-redo? h1))
(check-equal? (history-depth h1) 1)
(check-eq? (history-document h1) d1)
(check-eq? (history-undo-target h1) d0)
(check-false (history-redo-target h1))

;; ---------- undo / redo 往返 ----------
(define h2 (history-record h1 d1 d2))
(define-values (hu ok-u) (history-undo h2))
(check-true ok-u)
(check-eq? (history-document hu) d1)
(check-eq? (history-redo-target hu) d2)
(define-values (hr ok-r) (history-redo hu))
(check-true ok-r)
(check-eq? (history-document hr) d2)
;; 到边界后不再动
(check-false (let-values ([(h ok) (history-undo h0)]) ok))
(check-false (let-values ([(h ok) (history-redo h0)]) ok))

;; ---------- merge：折叠进当前步（不改 past / 深度），清 redo ----------
(define hm (history-merge h1 d0))
(check-equal? (history-depth hm) 1)
(check-eq? (history-document hm) d0)
(check-eq? (history-undo-target hm) d0)   ; 保留最早前态

;; ---------- set-current：只推进 current，不记步 ----------
(define hc (history-set-current h1 d2))
(check-equal? (history-depth hc) 1)
(check-eq? (history-document hc) d2)

;; ---------- 上限：past 只留最近 limit 步 ----------
(define hl (history-open d0 2))
(define hl1 (history-record hl d0 d1))
(define hl2 (history-record hl1 d1 d2))
(define hl3 (history-record hl2 d2 d0))
(check-equal? (history-depth hl3) 2)
(check-eq? (history-undo-target hl3) d2)   ; 最早那步（d0）已被丢弃

;; ---------- 开关：关掉后撤销不可用，编辑只推进 current ----------
(define hoff (history-set-enabled h2 #f))
(check-false (history-can-undo? hoff))
(check-false (history-can-redo? hoff))
(check-false (history-undo-target hoff))
(define hoff2 (history-record hoff d2 d0))
(check-eq? (history-document hoff2) d0)
(check-false (history-can-undo? hoff2))
(check-equal? (history-depth hoff2) 2)      ; past 保留，只是不记新步

;; ---------- clear：只留 current ----------
(define hcl (history-clear h2))
(check-false (history-can-undo? hcl))
(check-false (history-can-redo? hcl))
(check-eq? (history-document hcl) d2)

(displayln "editor/history.rkt: ok")
