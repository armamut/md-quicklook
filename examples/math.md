# Math

Formulas are typeset natively. Every formula in this file must render:
`make math-coverage` checks it.

## Inline

Euler: $e^{i\pi} + 1 = 0$, sets: $x \in \R$, $n \in \N$, $A \subseteq B$, $\emptyset$,
logic: $p \land q \implies r$, $\forall x \, \exists y$, $\therefore$, $\because$,
relations: $a \leq b$, $a \leqq b$, $a \ne b$, $a \not= b$, $a \approx b$, $a \equiv b \pmod{n}$,
arrows: $A \to B$, $A \twoheadrightarrow B$, $A \hookrightarrow B$, $f: x \mapsto x^2$,
Greek: $\alpha, \beta, \Gamma, \varGamma, \Alpha, \varepsilon, \vartheta$,
text: $\text{café}$, $\text{caf\'e}$, $a \& b$, $\checkmark$, $\blacksquare$, $\dots$.

Fractions $\frac{a}{b}$, $\tfrac{1}{2}$, binomials $\binom{n}{k}$, $\dbinom{n}{k}$,
roots $\sqrt{2}$, $\sqrt[3]{x}$, accents $\hat{x}$, $\bar{x}$, $\vec{v}$, $\dot{x}$, $\tilde{a}$,
operators $\sin x$, $\log_2 n$, $\lim_{n\to\infty}$, $\argmax_x f(x)$, $\operatorname{rank} A$,
fonts $\mathbb{R}$, $\mathcal{L}$, $\mathfrak{g}$, $\mathbf{v}$, $\boldsymbol{\mu}$, $\mathrm{d}x$.

## Display

$$
\int_0^\infty e^{-x^2} \, dx = \frac{\sqrt{\pi}}{2}
\qquad
\sum_{k=1}^{n} k = \frac{n(n+1)}{2}
$$

$$
\begin{align}
f(x) &= x^2 + 2x + 1 \\
     &= (x + 1)^2 \tag{1}
\end{align}
$$

$$
\begin{equation}
E = mc^2
\end{equation}
$$

$$
\begin{pmatrix} a & b \\ c & d \end{pmatrix}
\begin{bmatrix} x \\ y \end{bmatrix} =
\left[\begin{array}{cc|c}
1 & 2 & 3 \\
4 & 5 & 6
\end{array}\right]
$$

$$
|x| = \begin{cases} x & \text{if } x \ge 0 \\ -x & \text{otherwise} \end{cases}
\qquad
\begin{rcases} a & \text{if } x \\ b & \text{else} \end{rcases} \Rightarrow c
$$

$$
A \xrightarrow{f} B \xleftarrow[g]{h} C
\qquad
x \overset{!}{=} y
\qquad
a \stackrel{\text{def}}{=} b
\qquad
\underset{n \to \infty}{\lim} a_n
$$

$$
\overbrace{1 + 2 + \cdots + n}^{n \text{ terms}} = \underbrace{\frac{n(n+1)}{2}}_{\text{Gauss}}
\qquad
\overbracket{AB}^{k} \; \underbracket{AB}_{k}
\qquad
\overgroup{AB} \; \undergroup{AB} \; \utilde{AB}
$$

$$
\Overrightarrow{AB} \; \overleftharpoon{ac} \; \overrightharpoon{ac} \; \underleftarrow{AB} \; \underrightarrow{AB}
\; \underleftrightarrow{AB} \; \overlinesegment{AB} \; \underlinesegment{AB}
\qquad
\mathring{g} \; \dddot{a} \; \ddddot{a} \; \widecheck{ac} \; \underbar{X}
$$

$$
\nabla \times \mathbf{E} = -\frac{\partial \mathbf{B}}{\partial t}
\qquad
\oint_C \mathbf{F} \cdot d\mathbf{r}
\qquad
\iint_D f \, dA
$$
