# Copyright 2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

# Material Symbols Rounded — fonte de ICONES do Google, exigida pelo Clavis
# Shell. Nao existe em ::gentoo nem na GURU (verificado em 2026-09-03), e nao
# ha substituto: os temas x11-themes/*-icon-theme sao SVG resolvidos pela spec
# do freedesktop, enquanto o Components/MaterialSymbol.qml do Clavis renderiza
# um glifo de FONTE (`font.family` + codepoint). Mecanismos diferentes.
#
# As Nerd Fonts tambem nao servem: a Material Symbols ocupa U+E900-EB8D, faixa
# praticamente vaga nelas, e o Clavis declara `variableAxes` com FILL e opsz —
# exige a fonte VARIAVEL, que nenhuma Nerd Font e.

EAPI=8

inherit font

# O upstream nao versiona a fonte: as releases do repositorio sao de 2020 e nao
# tem assets. O que existe e o arquivo no git, entao fixamos o COMMIT em que
# ele foi atualizado pela ultima vez e versionamos pela data (_p<AAAAMMDD>,
# convencao de snapshot do Gentoo). Trocar a versao exige trocar o commit
# junto — os dois descrevem o mesmo fato.
MY_COMMIT="84ccef280841abfac506afc4ad4a2782f6d0a1d0"

# O nome do arquivo no upstream tem colchetes e virgulas (os eixos variaveis).
# Na URL eles precisam vir percent-encoded; o `->` renomeia o destino para algo
# que o Portage manipula sem sofrer com quoting.
MY_FILE="MaterialSymbolsRounded%5BFILL%2CGRAD%2Copsz%2Cwght%5D.ttf"

DESCRIPTION="Material Symbols Rounded, fonte de icones variavel do Google"
HOMEPAGE="https://github.com/google/material-design-icons"
SRC_URI="https://raw.githubusercontent.com/google/material-design-icons/${MY_COMMIT}/variablefont/${MY_FILE} -> ${P}.ttf"

LICENSE="Apache-2.0"
SLOT="0"
KEYWORDS="~amd64 ~arm64"

# Download de arquivo unico, sem mirror do Gentoo: nao ha o que espelhar e
# pedir para os mirrors carregarem isto seria abuso.
RESTRICT="mirror"

S="${WORKDIR}"
FONT_SUFFIX="ttf"

src_unpack() {
	# O SRC_URI e um .ttf, nao um tarball: o unpack default do Portage morre
	# ao nao reconhecer a extensao. Copiamos a mao.
	#
	# O nome do arquivo instalado NAO precisa ser o do upstream — o fontconfig
	# le a familia da tabela `name` interna da fonte, nao do caminho. Usamos um
	# nome sem colchetes para nao deixar armadilha de quoting para quem for
	# mexer nisto depois.
	cp "${DISTDIR}/${P}.ttf" "${S}/MaterialSymbolsRounded.ttf" \
		|| die "falha ao copiar a fonte do DISTDIR"
}
