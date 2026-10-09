#lang racket

;;; edit/test/completion-test.rkt —— 词补全链路验证（headless）
;;;
;;;   raco test edit/test/completion-test.rkt
;;;
;;; 覆盖：打开菜单（输入层 + 浮层）/ 打字 fallthrough 后刷新候选 / 接受替换前缀。

(require rackunit
         racket/file
         "../demo.rkt"
         "../session.rkt"
         "../document/document.rkt"
         "../feature/api.rkt"
         "../core/path.rkt"
         "../core/focus.rkt")

(define p (make-temporary-file "cp-~a.rkt"))
(display-to-file "alpha alphabet\n" p #:exists 'replace)

(define s (demo-session 80 24))
(define s1 (session-open-file s (normalize p)))
(define vid (session-edit-vid s1))

;; 在空行输入 "alph"，光标停在前缀后
(define s2 (session-ed-set-point! s1 vid 1 0))
(define s3 (step s2 (cmd-insert "alph")))
(check-equal? (session-view-string s3 vid) "alpha alphabet\nalph")

;; 打开补全菜单
(define s4 (step s3 (cmd-complete)))
(check-true (session-layer-active? s4 'complete))
(check-true (pair? (session-overlays s4)))

;; 输入层键表接管上下 / Enter / Esc（普通字符不在此，fallthrough 到文档键表）
(define lk (for/first ([l (in-list (session-layers s4))]) (layer-keys l)))
(check-pred cmd-complete-move? (keymap-lookup lk (key 'down)))
(check-pred cmd-complete-accept? (keymap-lookup lk (key 'enter)))
(check-pred cmd-complete-cancel? (keymap-lookup lk (key 'escape)))

;; 打字 fallthrough：插入 + 刷新（"alpha" == 前缀被排除，只剩 "alphabet"）
(define s5 (step s4 (cmd-insert "a")))
(check-equal? (session-view-string s5 vid) "alpha alphabet\nalpha")

;; 接受：把前缀换成候选
(define s6 (step s5 (cmd-complete-accept)))
(check-equal? (session-view-string s6 vid) "alpha alphabet\nalphabet")
(check-false (session-layer-active? s6 'complete))
(check-equal? (session-overlays s6) '())

;; 焦点移开 → focus-changed hook 取消菜单
(define t1 (step (session-ed-set-point! s6 vid 1 0) (cmd-insert "al")))
(define t2 (step t1 (cmd-complete)))
(check-true (session-layer-active? t2 'complete))
(define t3 (session-set-focus t2 (focus-set (session-focus t2) (session-panel-vid t2 panel-tree))))
(check-false (session-layer-active? t3 'complete))
(check-equal? (session-overlays t3) '())

;; 菜单所属文档关闭 → document-closed hook 取消菜单
(define u0 (session-set-focus t3 (focus-set (session-focus t3) vid)))
(define u1 (step (session-ed-set-point! u0 vid 1 0) (cmd-insert "al")))
(define u2 (step u1 (cmd-complete)))
(check-true (session-layer-active? u2 'complete))
(define u3 (session-close-document u2 (session-view-did u2 vid)))
(check-false (session-layer-active? u3 'complete))
(check-equal? (session-overlays u3) '())

;; 语言补全：模块导出作为候选（#lang racket/base + (require racket/list)）
(define p2 (make-temporary-file "cp2-~a.rkt"))
(display-to-file "#lang racket/base\n(require racket/list)\n(define (my-fn) 1)\n(fir"
                 p2 #:exists 'replace)
(define g1 (session-open-file u3 (normalize p2)))
(define gvid (session-edit-vid g1))
(define g2 (session-ed-set-point! g1 gvid 3 4))
;; 池在 worker 里算：轮询 before-render 直到菜单打开
(define (pump-until-menu s n)
  (cond
    [(session-layer-active? s 'complete) s]
    [(zero? n) s]
    [else (sleep 0.01) (pump-until-menu (session-prepare-render s) (sub1 n))]))
(define g3 (pump-until-menu (step g2 (cmd-complete)) 500))
(check-true (session-layer-active? g3 'complete))
(define g4 (step g3 (cmd-complete-accept)))
(check-equal? (session-view-string g4 gvid)
              "#lang racket/base\n(require racket/list)\n(define (my-fn) 1)\n(first")
(delete-file p2)

(delete-file p)
