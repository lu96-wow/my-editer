#lang racket

;;; plugins/test/completion-menu-test.rkt —— 补全菜单（headless）
;;;
;;;   raco test edit-rebuild/plugins/test/completion-menu-test.rkt
;;;
;;; 覆盖：
;;;   1. 候选较短、窗口被最小宽度（menu-width 的 12）撑宽时，菜单每行仍要铺满
;;;      窗口内容宽，否则选中项蓝底只占半行。
;;;   2. 模块集来自文件**内容**（#lang / (require …)），不是 .rkt 扩展名：
;;;      非 .rkt 文件带 #lang +(require) 也要能补出模块导出。

(require rackunit
         racket/file
         "../../core/app/app.rkt"
         "../../core/session/session.rkt"
         "../../core/session/adapter.rkt"
         "../../core/session/edit.rkt"
         "../../core/session/render.rkt"
         "../../core/path.rkt"
         "../catalog.rkt"
         "../ui/document.rkt")

(define (render s)
  (call-with-values (lambda () (session-render s #f)) (lambda (s* . _) s*)))

;; 菜单文档 did（没有 → #f）。
(define (menu-did s)
  (for/first ([did (in-list (session-document-ids s))]
              #:when (equal? (session-document-name s did) "*complete*"))
    did))

;; 渲染直到菜单出现（模块导出走 place worker，需等结果回来）或超时。
(define (wait-menu s [tries 200])
  (let loop ([s s] [i tries])
    (cond [(or (zero? i) (menu-did s)) s]
          [else (sleep 0.05) (loop (render s) (sub1 i))])))

;;; ---------- 1. 菜单行铺满内容宽 ----------

(define p (make-temporary-file "cm-~a.txt"))
(display-to-file "abc\nabd\n" p #:exists 'replace)

(define s0 (render (session-open-file (app-session 80 24 #:plugins enabled-plugins) (normalize p))))
(define evid (session-edit-vid s0))
;; 光标移到 (0,0) 并输入 "ab"：前缀短 → 候选短 → 触发最小宽度
(define s1 (render (session-insert (session-ed-set-point! s0 evid 0 0) "ab")))

(define mdid (menu-did s1))
(check-not-false mdid)
(define mvid (car (session-document-view-list s1 mdid)))
;; 外框宽 = view 宽；内容宽 = 外框 - 左右边框(各 1)
(define content-w (- (session-view-width s1 mvid) 2))
(define lines (string-split (session-view-string s1 mvid) "\n" #:trim? #f))
(check-true (> (length lines) 0))
(for ([line (in-list lines)])
  (check-equal? (string-length line) content-w))
(delete-file p)

;;; ---------- 2. 从 #lang / (require …) 取模块（与扩展名无关） ----------

;; 非 .rkt 扩展名，但文件声明了 #lang 且 require racket/list → 应补出 "first"。
(define p2 (make-temporary-file "cm2-~a.txt"))
(display-to-file "#lang racket/base\n(require racket/list)\n\n" p2 #:exists 'replace)
(define t0 (render (session-open-file (app-session 80 24 #:plugins enabled-plugins) (normalize p2))))
(define t1 (session-insert (session-ed-set-point! t0 (session-edit-vid t0) 3 0) "fir"))
(define t2 (wait-menu (render t1)))
(define tdid (menu-did t2))
(check-not-false tdid)
(check-not-false (regexp-match? #rx"first" (session-document-string t2 tdid)))
(delete-file p2)
