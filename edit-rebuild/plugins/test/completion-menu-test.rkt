#lang racket

;;; plugins/test/completion-menu-test.rkt —— 补全菜单渲染宽度（headless）
;;;
;;;   raco test edit-rebuild/plugins/test/completion-menu-test.rkt
;;;
;;; 回归：候选较短、窗口被最小宽度（menu-width 的 12）撑宽时，
;;; 菜单每行仍要铺满窗口内容宽，否则选中项蓝底只占半行。

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

;; 非 .rkt 文件 → 补全只用文档词（同步，不牵 worker）。
(define p (make-temporary-file "cm-~a.txt"))
(display-to-file "abc\nabd\n" p #:exists 'replace)

(define s0 (render (session-open-file (app-session 80 24 #:plugins enabled-plugins) (normalize p))))
(define evid (session-edit-vid s0))
;; 光标移到 (0,0) 并输入 "ab"：前缀短 → 候选短 → 触发最小宽度
(define s1 (render (session-insert (session-ed-set-point! s0 evid 0 0) "ab")))

(define menu-did
  (for/first ([did (in-list (session-document-ids s1))]
              #:when (equal? (session-document-name s1 did) "*complete*"))
    did))
(check-not-false menu-did)

(define mvid (car (session-document-view-list s1 menu-did)))
;; 外框宽 = view 宽；内容宽 = 外框 - 左右边框(各 1)
(define content-w (- (session-view-width s1 mvid) 2))
(define lines (string-split (session-view-string s1 mvid) "\n" #:trim? #f))
(check-true (> (length lines) 0))
(for ([line (in-list lines)])
  (check-equal? (string-length line) content-w))

(delete-file p)
