#lang racket

;;; edit-tui-rebuild/model/panel.rkt —— panel 资源
;;;
;;; panel 资源 = 一块面板的内容 + 固定尺寸策略 + 隐藏恢复信息。
;;; 它不存布局位置：rect 由 layout-solve 计算。
;;;
;;; views   : 这个 panel 里挂的 view（顺序 = Tab 顺序）
;;; active  : 当前显示的 view；#f = 空 panel
;;; fixed-w : #f | 非负整数；固定宽度
;;; fixed-h : #f | 非负整数；固定高度
;;; hidden? : 是否从渲染列表移除
;;; restore : 隐藏时记录的 (rect . parent-rect)，用于按比例放回
;;;
;;; 只有 active 在 views 里，panel 才有内容。

(provide (struct-out panel)
         (struct-out restore)
         make-panel
         make-empty-editor-panel
         panel-view
         panel-visible?
         panel-set-views
         panel-set-active
         panel-set-fixed
         panel-set-hidden
         panel-set-restore)

(struct restore (rect parent-rect) #:transparent)

(struct panel
  (id kind views active fixed-w fixed-h hidden? restore borders face weight)
  #:transparent)

(define (check-size-value who v)
  (unless (or (not v) (and (exact? v) (integer? v) (>= v 0)))
    (error who "fixed 尺寸要 #f 或非负整数：~a" v)))

(define (make-panel id kind
                    #:views [views '()]
                    #:active [active #f]
                    #:fixed-w [fixed-w #f]
                    #:fixed-h [fixed-h #f]
                    #:hidden? [hidden? #f]
                    #:restore [restore #f]
                    #:borders [borders '()]
                    #:face [face 'window-border]
                    #:weight [weight 0])
  (when (not id)
    (error 'make-panel "panel id 不能是 #f"))
  (unless (symbol? kind)
    (error 'make-panel "kind 要是 symbol：~a" kind))
  (unless (list? views)
    (error 'make-panel "views 要是 list：~a" views))
  (when (and active (not (memq active views)))
    (error 'make-panel "active 必须在 views 里：~a" active))
  (check-size-value 'make-panel fixed-w)
  (check-size-value 'make-panel fixed-h)
  (unless (boolean? hidden?)
    (error 'make-panel "hidden? 要是 bool：~a" hidden?))
  (unless (or (not restore) (restore? restore))
    (error 'make-panel "restore 要是 restore 或 #f：~a" restore))
  (unless (list? borders)
    (error 'make-panel "borders 要是 list：~a" borders))
  (panel id kind views active fixed-w fixed-h hidden? restore
         borders face weight))

(define (make-empty-editor-panel id
                                 #:borders [borders '()]
                                 #:face [face 'window-border]
                                 #:weight [weight 0])
  (make-panel id 'editor
              #:views '()
              #:active #f
              #:borders borders
              #:face face
              #:weight weight))

(define (panel-view p)
  (and (panel? p) (panel-active p)))

(define (panel-visible? p)
  (and (panel? p) (not (panel-hidden? p))))

(define (panel-set-views p views [active (and (pair? views) (car views))])
  (unless (list? views)
    (error 'panel-set-views "views 要是 list：~a" views))
  (when (and active (not (memq active views)))
    (error 'panel-set-views "active 必须在 views 里：~a" active))
  (struct-copy panel p [views views] [active active]))

(define (panel-set-active p active)
  (when (and active (not (memq active (panel-views p))))
    (error 'panel-set-active "active 必须在 views 里：~a" active))
  (struct-copy panel p [active active]))

(define (panel-set-fixed p axis value)
  (check-size-value 'panel-set-fixed value)
  (case axis
    [(w) (struct-copy panel p [fixed-w value])]
    [(h) (struct-copy panel p [fixed-h value])]
    [else (error 'panel-set-fixed "axis 要是 'w 或 'h：~a" axis)]))

(define (panel-set-hidden p hidden? [restore-value #f])
  (unless (boolean? hidden?)
    (error 'panel-set-hidden "hidden? 要是 bool：~a" hidden?))
  (struct-copy panel p [hidden? hidden?] [restore restore-value]))

(define (panel-set-restore p restore-value)
  (unless (or (not restore-value) (restore? restore-value))
    (error 'panel-set-restore "restore 要是 restore 或 #f：~a" restore-value))
  (struct-copy panel p [restore restore-value]))
