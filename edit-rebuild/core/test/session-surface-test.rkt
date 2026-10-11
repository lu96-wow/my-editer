#lang racket

;;; edit-rebuild/core/test/session-surface-test.rkt —— 面 / 停靠面板 / 刷新 / 输入行 / 日志
;;;
;;;   raco test edit-rebuild/core/test/session-surface-test.rkt

(require rackunit
         "../session/adapter.rkt"
         "../session/session.rkt"
         "../session/refresh.rkt"
         "../session/panel.rkt"
         "../session/prompt.rkt"
         "../session/bottom.rkt"
         "../surface/surface.rkt"
         "../ids.rkt")

(define s (session-blank 80 24))
(define-values (s1 edid evid) (session-add-document s "abc" 40 10 #:name "*edit*"))
(define-values (s2 _sid svid) (session-add-document s1 (panel-doc (list (list "status" #f))) 40 1 #:name "*status*"))
(define-values (s3 _iid ivid) (session-add-document s2 (panel-doc (list (list "> " #f))) 40 1 #:name "*input*"))

(define status (dock-surface 'status svid
                             (lambda (_s) (panel-doc (list (list "READY" #f))))
                             #f slot-bottom 'height 1))
(define input  (dock-surface 'input ivid (lambda (_s) #f) #f slot-bottom 'height 1))
(define s4 (session-add-surface (session-add-surface s3 status) input))

;; 面的登记与查询
(check-eq? (session-panel-vid s4 'status) svid)
(check-not-false (memv (session-view-did s4 svid) (session-panel-dids s4)))

;; 刷新：面 content 产出文档 → 装回 vid
(define s5 (session-refresh s4))
(check-equal? (session-view-string s5 svid) "READY")

;; 输入行：打开 → 打字 → 提交（label 后取文本 → 回调）
(define s6 (session-prompt-open s5 ivid "go: " (lambda (s text) (session-log! s text))))
(check-true (prompt? (session-prompt s6)))
(define s7 (let-values ([(s _ch) (session-ed-insert! s6 ivid "hi")]) s))
(check-equal? (session-view-string s7 ivid) "go: hi")
(define s8 (session-prompt-submit s7))
(check-false (session-prompt s8))
(check-equal? (session-log s8) '("hi"))

;; 同区域窗口互换（slot-side）：两个面，Tab 在它们之间切
(define-values (s9 _tdid tv) (session-add-document s8 "tree" 20 10 #:name "*tree*"))
(define-values (s10 _bdid bv) (session-add-document s9 "buf" 20 10 #:name "*buf*"))
(define tree    (dock-surface 'tree tv #f #f 'side 'height 'flex))
(define buffers (dock-surface 'buffers bv #f #f 'side 'height 'flex))
(define s11 (session-add-surface (session-add-surface s10 tree) buffers))
(check-true (session-visible? s11 tv))         ; 默认都可见
(define s12 (session-panel-swap s11))
;; 互换后同区域只显示一个
(check-not-eq? (session-visible? s12 tv) (session-visible? s12 bv))
(check-true (or (session-visible? s12 tv) (session-visible? s12 bv)))
(check-not-false (memv (session-focus-vid s12) (list tv bv)))
