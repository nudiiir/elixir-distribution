import 'package:flutter_test/flutter_test.dart';

import 'package:elixir_app/util/lettres.dart';

void main() {
  test('nombres en lettres', () {
    expect(nombreEnLettres(0), 'zéro');
    expect(nombreEnLettres(1), 'un');
    expect(nombreEnLettres(21), 'vingt et un');
    expect(nombreEnLettres(71), 'soixante et onze');
    expect(nombreEnLettres(75), 'soixante-quinze');
    expect(nombreEnLettres(80), 'quatre-vingts');
    expect(nombreEnLettres(81), 'quatre-vingt-un');
    expect(nombreEnLettres(91), 'quatre-vingt-onze');
    expect(nombreEnLettres(100), 'cent');
    expect(nombreEnLettres(200), 'deux cents');
    expect(nombreEnLettres(201), 'deux cent un');
    expect(nombreEnLettres(1000), 'mille');
    expect(nombreEnLettres(1234), 'mille deux cent trente-quatre');
    expect(nombreEnLettres(80000), 'quatre-vingt mille');
    expect(nombreEnLettres(1000000), 'un million');
    expect(nombreEnLettres(2500300),
        'deux millions cinq cent mille trois cents');
  });

  test('montant en lettres', () {
    expect(montantEnLettres(12500),
        'cent vingt-cinq dinars algériens');
    expect(montantEnLettres(12550),
        'cent vingt-cinq dinars algériens et cinquante centimes');
    expect(montantEnLettres(100), 'un dinar algérien');
    expect(montantEnLettres(0), 'zéro dinar algérien');
  });
}
