#lang racket

;;; lab-rebuild/base/face.rkt —— 需要带参数的 face 值（动态 face）+ 前景/背景分层
;;;
;;; core 的 face 是不透明值（core 不解释），由主题负责解释。
;;; 普通 face 用 symbol；需要参数（如括号按深度、词按词）时用这里的结构体。
;;;
;;; ⚠ 用 struct（#:prefab）而不是 pair / list：
;;;   1) 渲染补丁用 (overlay . face) 编码，后端靠 pair? 区分 overlay 和 face，
;;;      pair 形状的 face 会被误当成 overlay；
;;;   2) #:prefab 可跨 place / 进程序列化（插件后台进程要把 face 传回来）。
;;;
;;; palette-color：从主题的某个**调色板**（按 kind 选）里按 index 取模取颜色。
;;; 调色板项是 (list fg bg)，#f = 该维不设；所以同一种 kind 只写前景或只写背景由主题决定。
;;;
;;;   括号： (palette-color 'bracket level)           背景色，按嵌套深度
;;;   词：   (palette-color 'word (equal-hash-code w)) 前景色，按词的稳定哈希（同词同色）
;;;
;;; face-stack：一格的**分层外观**。多个插件写同一格时不去掉谁，而是把 face 依次叠起来；
;;; 主题按层解析 (fg bg)，**逐分量**合并（后层覆盖前层，某层 #f 的分量不覆盖）。
;;; 于是「括号背景」和「语法前景」可以同时存在：背景来自括号层，前景来自语法层。

(provide (struct-out palette-color)
         (struct-out face-stack)
         face-compose face-layers)

(struct palette-color (kind index) #:prefab)
;; kind  : symbol          主题 palettes 里的调色板名
;; index : exact-integer   取模取第 index 项

(struct face-stack (layers) #:prefab)
;; layers : (listof face)，先应用的在前；后层覆盖前层

;; 把新 face 叠到旧 face 上（旧 #f = 空 → 直接是新 face，单层不上 stack）。
(define (face-compose old new)
  (cond
    [(not old) new]
    [(not new) old]
    [(face-stack? old) (face-stack (append (face-stack-layers old) (list new)))]
    [else (face-stack (list old new))]))

;; 取一格的层列表（#f → 空表；单 face → 单元素表）。
(define (face-layers f)
  (cond
    [(not f) '()]
    [(face-stack? f) (face-stack-layers f)]
    [else (list f)]))
