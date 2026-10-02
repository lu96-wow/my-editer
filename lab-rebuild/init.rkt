#lang racket

;;; ============================================================================
;;; init.rkt —— 组合根：骨架配置（只挂 tree 一个组件）
;;; ============================================================================
;;;
;;; 整个应用就配在这里：一个 core 文档/视图当树、一张 pane 表、一个 layout 值。
;;; 加组件 = 加一行 pane + 改 layout。

(require "../core/editor.rkt"
         "host.rkt"
         "layout.rkt"
         "tree.rkt")

(provide setup render handle)

(define (setup root rows cols)
  (define ed (editor-open "" cols rows #:line-numbers? #f))     ; vid0 就是树的视图
  (define panes (hash 0 (pane 'tree 0 tree-sync tree-input tree-pointer #t (tree-open root))))
  (define h (host ed (hash) panes (leaf 0) 0 rows cols))
  (host-project! h))

(define (render h) (host-render h))

;;; ============================================================================
;;; 集成测试（骨架：树 + 宿主 + 帧）
;;; ============================================================================

(module+ test
  (require rackunit
           "../core/view/base/screen.rkt"
           "../core/text/document.rkt"
           "io.rkt"
           racket/file)

  (define (k name) (key name modifiers-none))

  (define d (make-temporary-file "rbinit-~a" 'directory))
  (define f (build-path d "a.txt"))
  (display-to-file "hello\nworld\n" f #:exists 'replace)

  (define h0 (setup d 10 60))
  (define-values (_h screen) (render h0))
  (check-equal? (list (screen-width screen) (screen-height screen)) '(60 10))
  (check-true (for/or ([rn (in-list (screen-row screen 0))]) (eq? (run-face rn) 'tree-root)))
  (check-equal? (host-focus h0) 0)

  ;; 下移到 a.txt → 回车打开（不抢焦点）
  (define h1 (handle (handle h0 (k 'down)) (k 'enter)))
  (check-true (hash-has-key? (host-opened h1) f))
  (check-equal? (host-focus h1) 0)

  ;; 新建文件（手敲字符走 key 路径）
  (define h2 (handle h1 (k #\n)))
  (check-true (regexp-match? #rx"新建文件" (editor-view-string (host-editor h2) (host-pane-vid h2 0))))
  ;; 输入行在视口最后一行（内容不足时补空行）
  (check-equal? (editor-view-point-line (host-editor h2) (host-pane-vid h2 0))
                (max (length (tree-lines (pane-state (host-pane h2 0)))) 9))
  (define h3 (for/fold ([x h2]) ([c (in-list '(#\m #\a #\d #\e))]) (handle x (k c))))
  (check-true (regexp-match? #rx"新建文件: made" (editor-view-string (host-editor h3) (host-pane-vid h3 0))))
  (define h4 (handle h3 (k 'enter)))
  (check-true (file-exists? (build-path d "made")))

  ;; resize
  (define h5 (handle h4 (resize 14 40)))
  (define-values (_h6 screen6) (render h5))
  (check-equal? (list (screen-width screen6) (screen-height screen6)) '(40 14))

  (delete-directory/files d)
  (displayln "lab-rebuild/init.rkt: all tests passed"))
