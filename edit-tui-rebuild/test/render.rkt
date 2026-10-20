#lang racket

;;; layout -> core panels -> bytes 渲染测试。
(require rackunit
         (only-in tui style->bytes)
         (only-in "../../core/editor.rkt"
                  make-buffer buffer-add-view!
                  view-width view-height
                  [panel-face c:panel-face]
                  [panel-weight c:panel-weight]
                  [panel-empty? c:panel-empty?])
         (only-in "../../core/view/border.rkt" panels->border-runs)
         "../config/theme/default.rkt"
         "../main.rkt")

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

;;; ---------- 焦点框：加一个空 panel，只改边框格 face ----------
(define ps-plain (layout->render-panels l2 area))
(define ps-focus (layout->render-panels l2 area #:focus-panel 'editor))
(check-equal? (length ps-focus) (add1 (length ps-plain)))
(define frame (last ps-focus))
(check-true (c:panel-empty? frame))
(check-equal? (c:panel-face frame) 'focused-border)
(check-true (> (c:panel-weight frame)
               (for/fold ([m 0]) ([p (in-list ps-plain)])
                 (max m (c:panel-weight p)))))

;; 焦点框不新增边框格：边框 run 的 (row col text) 完全一致，只是 face 变了
(define (run-shape r) (list (list-ref r 0) (list-ref r 1) (list-ref r 2)))
(check-equal? (map run-shape (panels->border-runs ps-plain))
              (map run-shape (panels->border-runs ps-focus)))
(check-true (for/or ([r (in-list (panels->border-runs ps-focus))])
              (eq? (list-ref r 3) 'focused-border)))

;; 焦点框的 face 真的画进了输出（主题里的 focused-border 样式）
(define focus-style (bytes->string/utf-8 (style->bytes 'focused-border)))
(check-true (string-contains? (bytes->string/utf-8 bytes1) focus-style))

;; 隐藏的 panel 不给焦点框（sidebar 可隐藏；editor 默认不可隐藏）
(define l-hidden
  (let-values ([(l* ok?) (layout-panel-hide l2 area 'filetree)])
    (check-true ok?)
    l*))
(check-equal? (length (layout->render-panels l-hidden area #:focus-panel 'filetree))
              2)

;; 焦点框不影响命中 / 导航投影
(check-equal? (length (layout->hit-panels l2 area)) 3)

(displayln "edit-tui-rebuild/test/render.rkt: ok")
