#lang racket

;;; edit/test/syntax-test.rkt —— 语法高亮链路验证（headless）
;;;
;;;   raco test edit/test/syntax-test.rkt
;;;
;;; 覆盖：open 时 rules 绑定插件 / 懒重算（句柄变了才写 face）/ palette-color 落到 face 端口
;;;       / 非关键字不上色 / face-compose 分层 / 主题解 palette-color。

(require rackunit
         racket/file
         "../demo.rkt"
         "../session.rkt"
         "../document/document.rkt"
         "../feature/api.rkt"
         "../core/face.rkt"
         "../core/path.rkt"
         "../theme/theme.rkt"
         "../theme/style.rkt"
         "../../core/editor.rkt"
         "../../core/text/document.rkt")

;; 写一个临时 .rkt 文件
(define p (make-temporary-file "hl-~a.rkt"))
(display-to-file "define x 1\n(let ((y 2)) y)\n" p #:exists 'replace)

(define s (demo-session 80 24))
(define s1 (session-open-file s (normalize p)))
(define did (session-file-did s1 (normalize p)))
(check-true (and did #t))

;; --- open 时经 rules 绑定了 syntax 插件 ---
(check-true (pair? (session-doc-plugins s1 did)))

;; --- 渲染前准备：把 fills 写进 face 端口 ---
(define s2 (session-prepare-render s1))
(define (face-at s row col)
  (document-face-at (editor-document-handle (session-ed s) did) row col))
;; 现在 words + syntax 都启用，一格可能是 face-stack：找其中的 keyword 层。
(define (kw-layer f)
  (for/first ([l (in-list (face-layers f))]
              #:when (and (palette-color? l) (eq? 'keyword (palette-color-kind l))))
    l))

(check-true (and (kw-layer (face-at s2 0 0)) #t))         ; "define" 关键字层
(check-false (kw-layer (face-at s2 0 7)))                 ; "x" 无关键字层
(check-true (and (kw-layer (face-at s2 1 1)) #t))         ; "let" 关键字层

;; --- lazy：同句柄不重算；编辑后句柄变 → 重算 ---
(define before (session-doc-applied s2 did))
(define s3 (session-prepare-render s2))
(check-eq? before (session-doc-applied s3 did))           ; 未变，缓存命中
(define s4 (session-insert s3 "lambda "))                 ; 光标在 0,0，插入
(define s5 (session-prepare-render s4))
(check-true (and (kw-layer (face-at s5 0 0)) #t))         ; 新文本 "lambda" 关键字层
(check-equal? (palette-color-index (kw-layer (face-at s5 0 0))) 4) ; keyword-list 里 lambda 的序号

;; --- 非 Racket 文件不绑插件 ---
(define p2 (make-temporary-file "hl-~a.txt"))
(display-to-file "define x\n" p2 #:exists 'replace)
(define s6 (session-open-file s5 (normalize p2)))
(define did2 (session-file-did s6 (normalize p2)))
(check-equal? (session-doc-plugins s6 did2) '())

;; --- face 分层 + 主题解 palette ---
(define st (theme-style default-theme (palette-color 'keyword 0)))
(check-pred style? st)
(check-true (and (style-fg st) #t))
(check-pred face-stack? (face-compose (palette-color 'keyword 0) 'some-face))
(check-pred style? (theme-style default-theme (face-compose (palette-color 'keyword 0) 'some-face)))

;; 清理
(delete-file p)
(delete-file p2)
