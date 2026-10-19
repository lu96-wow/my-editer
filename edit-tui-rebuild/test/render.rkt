#lang racket

;;; layout -> core panels -> bytes 渲染测试。
(require rackunit
         (only-in "../../core/editor.rkt"
                  make-buffer buffer-add-view!
                  view-width view-height)
         "../main.rkt")

(install-default-theme!)

(define area (rect 0 0 80 24))

(define ft-buffer (make-buffer "workspace\n  src\n  main.rkt"))
(define ft-view (buffer-add-view! ft-buffer 1 1))

(define state-buffer (make-buffer "state focus=editor msg=ready"))
(define state-view (buffer-add-view! state-buffer 1 1))

(define ft (make-panel 'filetree 'sidebar
                       #:views (list ft-view)
                       #:active ft-view
                       #:fixed-w 30
                       #:borders '(right)))
(define st (make-panel 'state 'status
                       #:views (list state-view)
                       #:active state-view
                       #:fixed-h 1))
(define ed (make-empty-editor-panel 'editor))

(define l0 (make-layout #:root (make-leaf 'editor)
                        #:panels (hash 'editor ed)
                        #:focus 'editor))
(define-values (l1 ok1?) (layout-panel-attach l0 'editor 'left ft))
(define-values (l2 ok2?) (layout-panel-attach l1 'editor 'down st))
(check-true ok1?)
(check-true ok2?)

(define-values (cache1 bytes1) (render-layout l2 area #:focus-panel 'editor))
(define text1 (bytes->string/utf-8 bytes1))
(check-true (> (bytes-length bytes1) 0))
(check-true (string-contains? text1 "workspace"))
(check-true (string-contains? text1 "state focus=editor"))
(check-equal? (view-width ft-view) 29)
(check-equal? (view-height ft-view) 24)
(check-equal? (view-width state-view) 50)
(check-equal? (view-height state-view) 1)

;; 同一帧 + 缓存 -> 空差量
(define-values (cache2 bytes2) (render-layout l2 area #:focus-panel 'editor #:cache cache1))
(check-equal? (bytes-length bytes2) 0)

;; 冷启动再渲染一次仍然有内容
(define-values (_cache3 bytes3) (render-layout l2 area #:focus-panel 'editor))
(check-true (string-contains? (bytes->string/utf-8 bytes3) "main.rkt"))

(displayln "edit-tui-rebuild/test/render.rkt: ok")
