#lang racket
;;; 20 —— 布局树 × core：tree → (listof panel) → screen
;;;
;;; 运行：racket temp/20-layout-tree.rkt
;;;
;;; 一个「编辑区 + 左侧文件树 + 右下状态栏」的可变布局：
;;;   · 隐藏文件树 → 编辑区占满；
;;;   · 把文件树移到下侧 → 重新排；
;;;   · 打印 cuts（拖拽缝用）。
;;; 生产者只产出 core 的 (listof panel)；渲染还是 render-display。

(require "../core/editor.rkt"
         "../edit-tui/layout/main.rkt")

(define W 60)
(define H 16)

(define eb (make-buffer "(define (f x)\n  (+ x 1))\n\n(f 41)\n" "main.rkt"))
(define ev (buffer-add-view! eb))
(define tb (make-buffer "src/\n  main.rkt\n  util.rkt\nREADME.md" "*tree*"))
(define tv (buffer-add-view! tb))

(define (area) (rect 0 0 W H))

;; 声明式：editor(3) / status(1) 竖叠放右侧；左侧 tree(4)。
;; dock 位置自动推边框：tree 左侧 → 只右；status 底部 → 只上；editor 中 → 全边。
(define (base-tree)
  (spec->tree
   (lay 'lr
        (pane 'tree #:view tv #:size 4 #:dock 'left)
        (lay 'tb
             (pane 'editor #:view ev #:size 3 #:dock 'center)
             (pane 'status #:view #f #:size 1 #:dock 'bottom)))))

(define (draw label tree)
  (define ps (tree->panels tree (area)))
  (panels-sync! ps)
  (printf "── ~a ──  panels=~a  cuts=~a\n~a\n\n"
          label (length ps)
          (for/list ([c (in-list (tree->cuts tree (area)))])
            (list (cut-axis c) (cut-offset c)))
          (screen->string (render-display ps ev W H))))

(define t (base-tree))
(draw "初始：左树 ｜ 右上编辑 右下状态" t)

(draw "隐藏文件树" (tree-hide t 'tree))

(draw "文件树移到下侧（tb 兄弟）" (tree-move t 'tree 'status 'tb #:side 'after))

(displayln "layout demo: OK")
